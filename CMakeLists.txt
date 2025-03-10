# ============================================================================ #
# Copyright (c) 2022 - 2023 NVIDIA Corporation & Affiliates.                   #
# All rights reserved.                                                         #
#                                                                              #
# This source code and the accompanying materials are made available under     #
# the terms of the Apache License 2.0 which accompanies this distribution.     #
# ============================================================================ #

cmake_minimum_required(VERSION 3.18 FATAL_ERROR)

# Policies
# ==============================================================================
if(POLICY CMP0068)
  cmake_policy(SET CMP0068 NEW)
  set(CMAKE_BUILD_WITH_INSTALL_NAME_DIR ON)
endif()

if(POLICY CMP0075)
  cmake_policy(SET CMP0075 NEW)
endif()

if(POLICY CMP0077)
  cmake_policy(SET CMP0077 NEW)
endif()

if(POLICY CMP0057)
  cmake_policy(SET CMP0057 NEW)
endif()

if(POLICY CMP0074)
  cmake_policy(SET CMP0074 NEW)
endif()

# CMP0116: Ninja generators transform `DEPFILE`s from `add_custom_command()`
# New in CMake 3.20. https://cmake.org/cmake/help/latest/policy/CMP0116.html
if(POLICY CMP0116)
  cmake_policy(SET CMP0116 OLD)
endif()

# Project setup
# ==============================================================================
project(cudaq LANGUAGES CXX C)

# Prevent In-source builds
# ==============================================================================
# Using the undocumented `CMAKE_DISABLE_IN_SOURCE_BUILDS` and
# `CMAKE_DISABLE_SOURCE_CHANCES` variables is not a good idea:  They can change
# without warning and they do not accomplish what they are supposed to do, i.e.,
# cmake files will still be created in the source tree.

# Going the extra mile to prevent the user from playing tricks with symlinks.
get_filename_component(REAL_PROJECT_SOURCE_DIR "${PROJECT_SOURCE_DIR}" REALPATH)
get_filename_component(REAL_PROJECT_BINARY_DIR "${PROJECT_BINARY_DIR}" REALPATH)

if("${REAL_PROJECT_SOURCE_DIR}" STREQUAL "${REAL_PROJECT_BINARY_DIR}")
  message(FATAL_ERROR
    "In-source builds are not permitted. You must run cmake in a separeted "
    "directory, e.g.:\n"
    "    mkdir build && cd build && cmake ..\n"
    "NOTE: Remeber to clean up the source tree by deleting the files already "
    "created by CMake, e.g, CMakeCache.txt and cmake.check_cache")
endif()

# Project globals
# ==============================================================================
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED on)
set(CMAKE_POSITION_INDEPENDENT_CODE TRUE)

# Generate a CompilationDatabase (compile_commands.json file) for our build,
# for use by clang_complete, YouCompleteMe, etc.
set(CMAKE_EXPORT_COMPILE_COMMANDS 1)

if(NOT CUDAQ_LLVM_VERSION)
  set(CUDAQ_LLVM_VERSION 16)
endif()

find_package(Git QUIET)
if(GIT_FOUND AND EXISTS "${PROJECT_SOURCE_DIR}/.git")
  # Update submodules as needed
  option(GIT_SUBMODULE "Check submodules during build" ON)
  if(GIT_SUBMODULE)
    message(STATUS "Submodule update")
    execute_process(COMMAND ${GIT_EXECUTABLE} -c submodule.tpls/llvm.update=none submodule update --init --recursive
                    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
                    RESULT_VARIABLE GIT_SUBMOD_RESULT)
    if(NOT GIT_SUBMOD_RESULT EQUAL "0")
        message(FATAL_ERROR "Cloning git submodules failed with ${GIT_SUBMOD_RESULT}, please checkout submodules manually")
    endif()
  endif()
endif()

if(NOT EXISTS "${PROJECT_SOURCE_DIR}/tpls/fmt/CMakeLists.txt")
    message(FATAL_ERROR "The submodules were not downloaded! GIT_SUBMODULE was turned off or failed. Please update submodules and try again.")
endif()

# Options
# ==============================================================================
option(CUDAQ_BUILD_TESTS "Build cudaq tests" ON)
option(CUDAQ_ENABLE_RPC_LOGGING "Enable verbose printout for client/server qpud connection." OFF)
option(CUDAQ_BUILD_RELOCATABLE_PACKAGE "Make CUDA Quantum install tree relocatable, system headers included." OFF)
option(CUDAQ_TEST_MOCK_SERVERS "Enable Remote QPU Tests via Mock Servers." OFF)
option(CUDAQ_DISABLE_RUNTIME "Build without the CUDA Quantum runtime, just the compiler toolchain." OFF)

if (CUDAQ_BUILD_RELOCATABLE_PACKAGE) 
  if (CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
    message(FATAL_ERROR "You must provide an install prefix if you are building the relocatable package.")
  endif()
endif()

include(ExternalProject)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Release" CACHE STRING "Choose Release or Debug" FORCE)
endif()

# Find and configure LLVM, Clang and MLIR
# ==============================================================================
# The user can specify the path to LLVM cmake directory using
# `-DLLVM_DIR=path/to/cmake/llvm`.  If this definition is not provided, we look
# for `llvm-config` tool.  The user can also provide a LLVM version to look for
# using `CUDAQ_LLVM_VERSION`, e.g. "-DCUDAQ_LLVM_VERSION=15".  Note that this
# version variable is set to the latest LLVM version by default, and setting it
# to an older version might break the project.
find_package(LLVM ${CUDAQ_LLVM_VERSION} CONFIG QUIET)

if(NOT LLVM_DIR)
  message(STATUS "LLVM_DIR not found, will try with llvm-config executable.")

  macro(find_llvm_config name version_major)
    set(extra_args ${ARGN})
    list(LENGTH extra_args extra_count)
    if (${extra_count} GREATER 0)
      list(GET extra_args 0 path)
      find_program(LLVM_CONFIG NAMES ${name} PATHS ${path} NO_DEFAULT_PATH
        DOC "Path to llvm-config tool")
    else()
      find_program(LLVM_CONFIG NAMES ${name} DOC "Path to llvm-config tool")
    endif()

    if(LLVM_CONFIG)
      execute_process(
        COMMAND ${LLVM_CONFIG} --version
        RESULT_VARIABLE LLVM_CONFIG_RESULT
        OUTPUT_VARIABLE LLVM_CONFIG_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
      )

      if(NOT LLVM_CONFIG_VERSION MATCHES "^${version_major}[.][0-9]+[.][0-9]+")
        unset(LLVM_CONFIG CACHE)
      endif()
    endif()
  endmacro()

  # First we try to find llvm-config in the llvm submodule.
  find_llvm_config(llvm-config ${CUDAQ_LLVM_VERSION}
    "${CMAKE_CURRENT_SOURCE_DIR}/tpls/llvm/build/bin")

  # Try to find a system llvm-config and make sure it is the correct version.
  if(NOT LLVM_CONFIG)
    find_llvm_config(llvm-config ${CUDAQ_LLVM_VERSION})
  endif()

  # If it is not the correct version, try finding llvm-config-VERSION
  if(NOT LLVM_CONFIG)
    find_llvm_config(llvm-config-${CUDAQ_LLVM_VERSION} ${CUDAQ_LLVM_VERSION})
    if (LLVM_CONFIG)
      set(NVQPP_LLVM_EXECUTABLE_SUFFIX -${CUDAQ_LLVM_VERSION})
    endif()
  endif()

  execute_process(
    COMMAND ${LLVM_CONFIG} --cmakedir
    RESULT_VARIABLE LLVM_CONFIG_RESULT
    OUTPUT_VARIABLE LLVM_CONFIG_CMAKE_DIR
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
  )

  if(LLVM_CONFIG_RESULT)
    message(FATAL_ERROR
      "Could not find suitable llvm-config(-${CUDAQ_LLVM_VERSION}).\
      \nTry providing valid -DLLVM_DIR=/path/to/llvm/lib/cmake/llvm.")
  else()
    find_package(LLVM ${CUDAQ_LLVM_VERSION} REQUIRED CONFIG
      HINTS ${LLVM_CONFIG_CMAKE_DIR} NO_DEFAULT_PATH)
  endif()
endif()

if(NOT MLIR_DIR)
  set(MLIR_DIR ${LLVM_BINARY_DIR}/lib/cmake/mlir)
endif()

find_package(MLIR REQUIRED CONFIG)

if(NOT Clang_DIR)
  set(Clang_DIR ${LLVM_BINARY_DIR}/lib/cmake/clang)
endif()

find_package(Clang REQUIRED CONFIG)

message(STATUS "Using LLVMConfig.cmake in: ${LLVM_DIR}")
message(STATUS "Using ClangConfig.cmake in: ${Clang_DIR}")
message(STATUS "Using MLIRConfig.cmake in: ${MLIR_DIR}")

set(LLVM_RUNTIME_OUTPUT_INTDIR ${CMAKE_BINARY_DIR}/bin)
set(LLVM_LIBRARY_OUTPUT_INTDIR ${CMAKE_BINARY_DIR}/lib)
set(MLIR_BINARY_DIR ${CMAKE_BINARY_DIR})

list(APPEND CMAKE_MODULE_PATH "${MLIR_CMAKE_DIR}")
list(APPEND CMAKE_MODULE_PATH "${LLVM_CMAKE_DIR}")
list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake/Modules")

include(CUDAQRPath)
include(TableGen)
include(AddLLVM)
include(AddMLIR)
include(HandleLLVMOptions)

# Add LLVM, Clang and MLIR headers to the include path
include_directories(SYSTEM
  ${LLVM_INCLUDE_DIRS}
  ${CLANG_INCLUDE_DIRS}
  ${MLIR_INCLUDE_DIRS})

link_directories(${LLVM_BUILD_LIBRARY_DIR})
add_definitions(${LLVM_DEFINITIONS})

# Define the default arguments to use with 'lit', and an option for the user to
# override.
set(LIT_ARGS_DEFAULT "-sv")

if(MSVC_IDE OR XCODE)
  set(LIT_ARGS_DEFAULT "${LIT_ARGS_DEFAULT} --no-progress-bar")
endif()

set(LLVM_LIT_ARGS "${LIT_ARGS_DEFAULT}" CACHE STRING "Default options for lit")

# CUDA Quantum configuration
# ==============================================================================
message(STATUS "Build type is ${CMAKE_BUILD_TYPE}")

set(CUDAQ_MAIN_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}) # --src-root
set(CUDAQ_MAIN_INCLUDE_DIR ${CUDAQ_MAIN_SRC_DIR}/include)

set(CUDAQ_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR})
set(CUDAQ_BINARY_DIR ${CMAKE_CURRENT_BINARY_DIR})
set(CUDAQ_CMAKE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
set(CUDAQ_INCLUDE_DIR ${CMAKE_CURRENT_BINARY_DIR}/include)
set(CUDAQ_LIBRARY_DIR ${CMAKE_BINARY_DIR}/lib)
set(CUDAQ_TOOLS_DIR ${CMAKE_BINARY_DIR}/bin)

list(APPEND CMAKE_MODULE_PATH "${CUDAQ_CMAKE_DIR}")

include(AddCUDAQ)

# Add CUDA Quantum files to the include path
include_directories(BEFORE
  ${CUDAQ_SOURCE_DIR}/include
  ${CUDAQ_BINARY_DIR}/include)

# Installing the headers and docs needs to depend on generating any public
# tablegen'd targets.
add_custom_target(cudaq-headers)
set_target_properties(cudaq-headers PROPERTIES FOLDER "Misc")
add_custom_target(cudaq-doc)

# Install
# ==============================================================================

# If building normally, this will add the required 
# system headers to the cudaq-quake include paths.
if (NOT CUDAQ_BUILD_RELOCATABLE_PACKAGE)
  foreach(dir ${CMAKE_CXX_IMPLICIT_LINK_DIRECTORIES})
    set(CUDAQ_CXX_NVQPP_LINK_STR "${CUDAQ_CXX_NVQPP_LINK_STR} -L${dir}")
  endforeach()
else()
  # If we are building the relocatable package, 
  # we need to do a bit more for Apple Mac
  if (APPLE) 
    foreach(dir ${CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES})
      if (${dir} MATCHES ".*/c.*/v1") 
        # Copy the bundled c++ includes from theClang install to ours
        file(COPY ${dir} DESTINATION ${CMAKE_INSTALL_PREFIX}/include/c++/)
        # We want the driver to include the bundled C++ headers from Clang
        set(CUDAQ_CXX_NVQPP_INCLUDE_STR "${CUDAQ_CXX_NVQPP_INCLUDE_STR} -I ${CMAKE_INSTALL_PREFIX}/include/c++/v1")
      elseif(${dir} MATCHES ".*sdk/usr/include") 
        # We want the driver to include the SDK/usr/include dir
        set(CUDAQ_CXX_NVQPP_INCLUDE_STR "${CUDAQ_CXX_NVQPP_INCLUDE_STR} -I ${dir}")
      endif()  
    endforeach()
  endif() 
endif()

configure_file("${CMAKE_SOURCE_DIR}/include/nvqpp_config.h.in"
  "${CUDAQ_BINARY_DIR}/include/nvqpp_config.h")

install(FILES ${CMAKE_BINARY_DIR}/include/nvqpp_config.h
  DESTINATION include/nvqpp)

# Third-party libraries (tpls)
# ==============================================================================
set(FMT_INSTALL ON)
add_subdirectory(tpls/fmt)
include_directories(SYSTEM tpls/json/include)

# Add spdlog 
set(SPDLOG_BUILD_SHARED OFF)
set(SPDLOG_FMT_EXTERNAL ON)
add_subdirectory(tpls/spdlog)
set_property(TARGET spdlog APPEND PROPERTY INTERFACE_SYSTEM_INCLUDE_DIRECTORIES)
target_compile_options(spdlog PRIVATE -Wno-covered-switch-default)

# May want to provide a hook to this
if (CUDAQ_ENABLE_RPC_LOGGING)
  set(RPCLIB_ENABLE_LOGGING TRUE)
endif()
set(RPCLIB_EXTRA_BUILD_FLAGS "-Wno-suggest-override;-Wno-documentation;-Wno-unused-variable;-Wno-unused-but-set-variable;-Wno-unsafe-buffer-usage")
add_subdirectory(tpls/rpclib EXCLUDE_FROM_ALL)
set_property(TARGET rpc APPEND PROPERTY INTERFACE_SYSTEM_INCLUDE_DIRECTORIES)

# Check for CUDA Support
# ==============================================================================
include(CheckLanguage)
check_language(CUDA)
set(CUDA_FOUND FALSE)
if(CMAKE_CUDA_COMPILER)
  if (NOT CUDA_ARCH_BIN)
    set(CUDA_ARCH_BIN 80)
  endif()
  set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -shared -std=c++17 -gencode arch=compute_${CUDA_ARCH_BIN},code=sm_${CUDA_ARCH_BIN}  --compiler-options -fPIC")

  enable_language(CUDA)
  set(CUDA_FOUND TRUE)
  set(CMAKE_CUDA_STANDARD 17)
  set(CMAKE_CUDA_STANDARD_REQUIRED TRUE)
  message(STATUS "Cuda language found. Will build NVIDIA Platform.")
endif()

# Check for CURL and OpenSSL
find_package(CURL COMPONENTS HTTP HTTPS QUIET) 
find_package(OpenSSL QUIET)

# Directory setup
# ==============================================================================
add_subdirectory(cmake)
add_subdirectory(include)
add_subdirectory(lib)
if (NOT CUDAQ_DISABLE_RUNTIME)
  add_subdirectory(runtime)
endif()
add_subdirectory(tools)
add_subdirectory(utils)

# Python setup
# ==============================================================================
if(CUDAQ_BUILD_TESTS)
  set(INSTALL_GTEST OFF)
  add_subdirectory(tpls/googletest-src)
  target_compile_options(gtest PRIVATE -Wno-covered-switch-default)
  include(GoogleTest)
  include(CTest)
  if (NOT CUDAQ_DISABLE_RUNTIME)
    add_subdirectory(unittests)
    add_subdirectory(docs)
  endif()
  add_subdirectory(test)
endif()

# Users may specify  `-DCUDAQ_ENABLE_PYTHON=TRUE`, otherwise the python bindings
# will not be built.
if (CUDAQ_ENABLE_PYTHON)
  add_subdirectory(tpls/pybind11)
  add_subdirectory(python)
endif()

if (CUDAQ_BUILD_RELOCATABLE_PACKAGE) 
  # Grab the Clang system headers / resource-dir
  install(DIRECTORY ${LLVM_BINARY_DIR}/lib/clang/ DESTINATION ${CMAKE_INSTALL_PREFIX}/lib/clang)

  # Install the executables we need
  install(PROGRAMS ${LLVM_BINARY_DIR}/bin/llc DESTINATION bin)
  install(PROGRAMS ${LLVM_BINARY_DIR}/bin/clang-${CUDAQ_LLVM_VERSION} DESTINATION bin)
  install(PROGRAMS ${LLVM_BINARY_DIR}/bin/clang DESTINATION bin)
  install(PROGRAMS ${LLVM_BINARY_DIR}/bin/clang++ DESTINATION bin)
endif()
