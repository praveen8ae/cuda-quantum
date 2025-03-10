#!/bin/bash

# ============================================================================ #
# Copyright (c) 2022 - 2023 NVIDIA Corporation & Affiliates.                   #
# All rights reserved.                                                         #
#                                                                              #
# This source code and the accompanying materials are made available under     #
# the terms of the Apache License 2.0 which accompanies this distribution.     #
# ============================================================================ #

# Usage:
# bash scripts/build_cudaq.sh
# -or-
# bash scripts/build_cudaq.sh -c DEBUG
# -or-
# LLVM_INSTALL_PREFIX=/path/to/dir bash scripts/build_cudaq.sh
# -or-
# CUDAQ_INSTALL_PREFIX=/path/for/installing/cudaq LLVM_INSTALL_PREFIX=/path/to/dir bash scripts/build_cudaq.sh
# -or-
# CUQUANTUM_INSTALL_PREFIX=/path/to/dir bash scripts/build_cudaq.sh
#
# Prerequisites:
# - git, ninja-build, cmake, python3, libpython3-dev, libstdc++-11-dev, libblas-dev (all available via apt install)
# - LLVM binaries, libraries, and headers as built by scripts/build_llvm.sh.
# - To include simulator backends that use cuQuantum the packages cuquantum and cuquantum-dev are needed. 
# - Additional python dependencies for running and testing: lit pytest numpy (available via pip install)

LLVM_INSTALL_PREFIX=${LLVM_INSTALL_PREFIX:-/opt/llvm}
CUQUANTUM_INSTALL_PREFIX=${CUQUANTUM_INSTALL_PREFIX:-/opt/nvidia/cuquantum}
CUDAQ_INSTALL_PREFIX=${CUDAQ_INSTALL_PREFIX:-"$HOME/.cudaq"}

# Process command line arguments
(return 0 2>/dev/null) && is_sourced=true || is_sourced=false
build_configuration=Release

__optind__=$OPTIND
OPTIND=1
while getopts ":c:" opt; do
  case $opt in
    c) build_configuration="$OPTARG"
    ;;
    \?) echo "Invalid command line option -$OPTARG" >&2
    if $is_sourced; then return 1; else exit 1; fi
    ;;
  esac
done
OPTIND=$__optind__

# Run the script from the top-level of the repo
working_dir=`pwd`
this_file_dir=`dirname "$(readlink -f "${BASH_SOURCE[0]}")"`
repo_root=$(cd "$this_file_dir" && git rev-parse --show-toplevel)
cd "$repo_root"

# Clone the submodules (skipping llvm)
echo "Cloning submodules..."
git -c submodule.tpls/llvm.update=none submodule update --init --recursive

llvm_config="$LLVM_INSTALL_PREFIX/bin/llvm-config"
llvm_lib_dir=`"$llvm_config" --libdir 2>/dev/null`
if [ ! -d "$llvm_lib_dir" ]; then
  echo "Could not find llvm libraries."

  # Build llvm libraries from source and install them in the install directory
  llvm_build_script=`pwd`/scripts/build_llvm.sh
  cd "$working_dir" && source "$llvm_build_script" -c $build_configuration && cd "$repo_root"
  (return 0 2>/dev/null) && is_sourced=true || is_sourced=false

  llvm_lib_dir=`"$llvm_config" --libdir 2>/dev/null`
  if [ ! -d "$llvm_lib_dir" ]; then
    echo "Failed to find llvm libraries directory $llvm_lib_dir."
    if $is_sourced; then return 1; else exit 1; fi
  fi
else 
  echo "Configured C compiler: $CC"
  echo "Configured C++ compiler: $CXX"
fi

# Check if a suitable CUDA version is installed
cuda_version=`nvcc --version 2>/dev/null | grep -o 'release [0-9]*\.[0-9]*' | cut -d ' ' -f 2`
cuda_major=`echo $cuda_version | cut -d '.' -f 1`
cuda_minor=`echo $cuda_version | cut -d '.' -f 2`
if [ ! -x "$(command -v nvidia-smi)" ] && [ "$COMPILE_GPU_BACKENDS" != "true" ] ; then # the second check here is to avoid having to use https://discuss.huggingface.co/t/how-to-deal-with-no-gpu-during-docker-build-time/28544 
  echo "No GPU detected - GPU backends will be omitted from the build."
  custatevec_flag=""
elif [ "$cuda_version" = "" ] || [ "$cuda_major" -lt "11" ] || ([ "$cuda_minor" -lt "8" ] && [ "$cuda_major" -eq "11" ]); then
  echo "CUDA version requirement not satisfied (required: >= 11.8, got: $cuda_version)."
  echo "GPU backends will be omitted from the build."
  custatevec_flag=""
else 
  echo "CUDA version $cuda_version detected."
  if [ ! -d "$CUQUANTUM_INSTALL_PREFIX" ]; then
    echo "No cuQuantum installation detected. Please set the environment variable CUQUANTUM_INSTALL_PREFIX to enable cuQuantum integration."
    echo "GPU backends will be omitted from the build."
    custatevec_flag=""
  else
    echo "Using cuQuantum installation in $CUQUANTUM_INSTALL_PREFIX."
    custatevec_flag="-DCUSTATEVEC_ROOT=$CUQUANTUM_INSTALL_PREFIX"
  fi
fi

# Prepare the build directory
mkdir -p "$CUDAQ_INSTALL_PREFIX/bin"
mkdir -p "$working_dir/build" && cd "$working_dir/build" && rm -rf * 
mkdir -p logs && rm -rf logs/* 

# Generate CMake files 
# (utils are needed for custom testing tools, e.g. CircuitCheck)
cmake_common_linker_flags_init=""
llvm_dir="$llvm_lib_dir/cmake/llvm"
echo "Preparing CUDA Quantum build with LLVM_DIR=$llvm_dir..."
cmake -G Ninja "$repo_root" \
  -DCMAKE_INSTALL_PREFIX="$CUDAQ_INSTALL_PREFIX" \
  -DLLVM_DIR="$llvm_dir" \
  -DNVQPP_LD_PATH="$NVQPP_LD_PATH" \
  -DCMAKE_BUILD_TYPE=$build_configuration \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DCUDAQ_ENABLE_PYTHON=TRUE \
  -DLLVM_BUILD_UTILS=ON \
  -DCMAKE_EXE_LINKER_FLAGS_INIT="$cmake_common_linker_flags_init" \
  -DCMAKE_MODULE_LINKER_FLAGS_INIT="$cmake_common_linker_flags_init" \
  -DCMAKE_SHARED_LINKER_FLAGS_INIT="$cmake_common_linker_flags_init" \
  $custatevec_flag 2> logs/cmake_error.txt 1> logs/cmake_output.txt

# Build and install CUDAQ
echo "Building CUDA Quantum with configuration $build_configuration..."
logs_dir=`pwd`/logs
echo "The progress of the build is being logged to $logs_dir/ninja_output.txt."
ninja install 2> "$logs_dir/ninja_error.txt" 1> "$logs_dir/ninja_output.txt"
if [ ! "$?" -eq "0" ]; then
  echo "Build failed. Please check the files in the $logs_dir directory."
  cd "$working_dir" && if $is_sourced; then return 1; else exit 1; fi
else
  cp "$repo_root/LICENSE" "$CUDAQ_INSTALL_PREFIX/LICENSE"
  cp "$repo_root/NOTICE" "$CUDAQ_INSTALL_PREFIX/NOTICE"
  cd "$working_dir" && echo "Installed CUDA Quantum in directory: $CUDAQ_INSTALL_PREFIX"
fi
