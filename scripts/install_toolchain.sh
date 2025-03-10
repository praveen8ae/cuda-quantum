#!/bin/bash

# ============================================================================ #
# Copyright (c) 2022 - 2023 NVIDIA Corporation & Affiliates.                   #
# All rights reserved.                                                         #
#                                                                              #
# This source code and the accompanying materials are made available under     #
# the terms of the Apache License 2.0 which accompanies this distribution.     #
# ============================================================================ #

# This script installs the specified C/C++ toolchain, 
# and exports the CC and CXX environment variables.
#
# Usage:
#   source scripts/install_toolchain.sh -t <toolchain>
# -or-
#   source scripts/install_toolchain.sh -t <toolchain> -e path/to/dir
#
# where <toolchain> cam be either gcc11, clang15, or llvm. 
# The -e option creates a init_command.sh file in the given directory that 
# can be used to reinstall the same toolchain if needed.

(return 0 2>/dev/null) && is_sourced=true || is_sourced=false
__optind__=$OPTIND
OPTIND=1
toolchain=gcc11
while getopts ":t:e:" opt; do
  case $opt in
    t) toolchain="$OPTARG"
    ;;
    e) export_dir="$OPTARG"
    ;;
    \?) echo "Invalid command line option -$OPTARG" >&2
    if $is_sourced; then return 1; else exit 1; fi
    ;;
  esac
done
OPTIND=$__optind__

function temp_install_if_command_unknown {
    if [ ! -x "$(command -v $1)" ]; then
        apt-get install -y --no-install-recommends $2
        APT_UNINSTALL="$APT_UNINSTALL $2"
    fi
}

if [ "$toolchain" = "gcc11" ] ; then

    apt-get update && apt-get install -y --no-install-recommends gcc g++
    CC=/usr/bin/gcc-11 && CXX=/usr/bin/g++-11

elif [ "$toolchain" = "clang15" ]; then

    apt-get update && apt-get install -y --no-install-recommends wget gnupg
    wget -O - https://apt.llvm.org/llvm-snapshot.gpg.key | apt-key add -
    add-apt-repository "deb http://apt.llvm.org/jammy/ llvm-toolchain-jammy-15 main"
    apt-get update && apt-get install -y --no-install-recommends llvm-15 clang-15 terminfo
    CC=/usr/lib/llvm-15/bin/clang && CXX=/usr/lib/llvm-15/bin/clang++

elif [ "$toolchain" = "llvm" ]; then

    # We build the llvm toolchain against libstdc++ for now rather than building the runtime libraries as well.
    apt-get update && apt-get install -y --no-install-recommends libstdc++-11-dev

    LLVM_INSTALL_PREFIX=${LLVM_INSTALL_PREFIX:-/opt/llvm}
    if [ ! -f "$LLVM_INSTALL_PREFIX/bin/clang" ] || [ ! -f "$LLVM_INSTALL_PREFIX/bin/clang++" ] || [ ! -f "$LLVM_INSTALL_PREFIX/bin/ld.lld" ]; then

        this_file_dir=`dirname "$(readlink -f "${BASH_SOURCE[0]}")"` # alternatively, we could pass the script path instead of llvm-toolchain        
        if [ ! -d "$LLVM_SOURCE" ]; then
            mkdir -p "$HOME/.llvm_project"
            llvm_tmp_dir=`mktemp -d -p "$HOME/.llvm_project"` && LLVM_SOURCE="$llvm_tmp_dir"
            apt-get update && apt-get install -y --no-install-recommends git
            git clone -b main --single-branch --depth 1 https://github.com/llvm/llvm-project "$LLVM_SOURCE"
        fi
        
        temp_install_if_command_unknown ninja ninja-build
        temp_install_if_command_unknown cmake cmake
        temp_install_if_command_unknown gcc gcc
        temp_install_if_command_unknown g++ g++
        LLVM_INSTALL_PREFIX="$LLVM_INSTALL_PREFIX" bash "$this_file_dir/build_llvm.sh" -s "$LLVM_SOURCE" -c Release -p "clang;lld"
        if [ -d "$llvm_tmp_dir" ]; then
            rm -rf "$llvm_tmp_dir"
        fi

        if [ "$APT_UNINSTALL" != "" ]; then
            echo "Uninstalling packages used for bootstrapping: $APT_UNINSTALL"
            apt-get remove -y $APT_UNINSTALL && apt-get autoremove -y
        fi
    fi

    CC="$LLVM_INSTALL_PREFIX/bin/clang" && CXX="$LLVM_INSTALL_PREFIX/bin/clang++"
    if [ ! -x "$(command -v ld)" ] && [ -x "$(command -v "$LLVM_INSTALL_PREFIX/bin/ld.lld")" ]; then
        # Not the most up-to-date reference, but maybe a good starting point for reference:
        # https://maskray.me/blog/2020-12-19-lld-and-gnu-linker-incompatibilities
        ln -s "$LLVM_INSTALL_PREFIX/bin/ld.lld" /usr/bin/ld
        created_ld_sym_link=$?
        if [ "$created_ld_sym_link" = "" ] || [ ! "$created_ld_sym_link" -eq "0" ]; then
            echo "Failed to configure a linker. The lld linker can be used by adding the linker flag --ld-path=\"$LLVM_INSTALL_PREFIX/bin/ld.lld\"."
        else 
            echo "Setting lld linker as the default linker."
        fi
    fi

else

    echo "The requested toolchain cannot be installed by this script."
    echo "Supported toolchains: llvm, clang15, gcc11."
    if $is_sourced; then return 1; else exit 1; fi

fi

if [ -x "$(command -v "$CC")" ] && [ -x "$(command -v "$CXX")" ]; then
    apt-get autoremove -y --purge && apt-get clean && rm -rf /var/lib/apt/lists/* 
    export CC="$CC" && export CXX="$CXX"
    echo "Installed $toolchain toolchain."
    
    if [ "$export_dir" != "" ]; then 
        mkdir -p "$export_dir"
        this_file=`readlink -f "${BASH_SOURCE[0]}"`
        cat "$this_file" > "$export_dir/install_toolchain.sh"
        env_variables="LLVM_INSTALL_PREFIX=$LLVM_INSTALL_PREFIX LLVM_SOURCE=$LLVM_SOURCE"
        echo "$env_variables source \"$export_dir/install_toolchain.sh\" -t $toolchain" > "$export_dir/init_command.sh"
    fi
else
    echo "Failed to install $toolchain toolchain."
    if $is_sourced; then return 10; else exit 10; fi
fi
