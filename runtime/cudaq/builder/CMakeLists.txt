# ============================================================================ #
# Copyright (c) 2022 - 2023 NVIDIA Corporation & Affiliates.                   #
# All rights reserved.                                                         #
#                                                                              #
# This source code and the accompanying materials are made available under     #
# the terms of the Apache License 2.0 which accompanies this distribution.     #
# ============================================================================ #

set(LIBRARY_NAME cudaq-builder)

add_library(cudaq-builder SHARED kernel_builder.cpp QuakeValue.cpp)
target_include_directories(cudaq-builder PUBLIC ${CMAKE_SOURCE_DIR}/runtime)
target_link_libraries(cudaq-builder
  PRIVATE
    cudaq
    fmt::fmt-header-only
    nvqir
    cudaq-mlir-runtime
)

cudaq_library_set_rpath(${LIBRARY_NAME})

install(TARGETS cudaq-builder DESTINATION lib)
