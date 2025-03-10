# ============================================================================ #
# Copyright (c) 2022 - 2023 NVIDIA Corporation & Affiliates.                   #
# All rights reserved.                                                         #
#                                                                              #
# This source code and the accompanying materials are made available under     #
# the terms of the Apache License 2.0 which accompanies this distribution.     #
# ============================================================================ #

set (CMAKE_CXX_FLAGS
     "${CMAKE_CXX_FLAGS} -Wno-attributes -Wno-ctad-maybe-unsupported")

set(CUDAQ_RUNTIME_TEST_SOURCES 
  # Integration tests
  integration/adjoint_tester.cpp
  integration/builder_tester.cpp
  integration/ccnot_tester.cpp
  integration/deuteron_exp_inst.cpp
  integration/deuteron_variational_tester.cpp
  integration/ghz_nisq_tester.cpp
  integration/gradient_tester.cpp
  integration/grover_test.cpp
  integration/nlopt_tester.cpp
  integration/qpe_ftqc.cpp
  integration/qpe_nisq.cpp
  integration/qubit_allocation.cpp
  integration/vqe_tester.cpp
  integration/bug67_vqe_then_sample.cpp
  integration/bug77_vqe_with_shots.cpp
  integration/bug116_cusv_measure_bug.cpp
  integration/async_tester.cpp
  integration/negative_controls_tester.cpp
  integration/observe_result_tester.cpp
  integration/noise_tester.cpp
  integration/get_state_tester.cpp
  qir/NVQIRTester.cpp
  qis/QubitQISTester.cpp
  common/MeasureCountsTester.cpp
  common/NoiseModelTester.cpp
)

# Make it so we can get function symbols
set (CMAKE_ENABLE_EXPORTS TRUE)

## This Macro allows us to create a test_runtime executable for 
## the sources in CUDAQ_RUNTIME_TEST_SOURCE for a specific backend simulator
macro (create_tests_with_backend NVQIR_BACKEND EXTRA_BACKEND_TESTER) 
  set(TEST_EXE_NAME "test_runtime_${NVQIR_BACKEND}")
  add_executable(${TEST_EXE_NAME} main.cpp ${CUDAQ_RUNTIME_TEST_SOURCES} ${EXTRA_BACKEND_TESTER})
  target_compile_definitions(${TEST_EXE_NAME} PRIVATE -DNVQIR_BACKEND_NAME=${NVQIR_BACKEND})
  target_include_directories(${TEST_EXE_NAME} PRIVATE .)
  # On GCC, the default is --as-needed for linking, and therefore the 
  # nvqir-simulation plugin may not get picked up. This works as is on clang 
  # But here we add it purposefully to avoid that bug. 
  if (CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND NOT APPLE)
    target_link_options(${TEST_EXE_NAME} PRIVATE -Wl,--no-as-needed)
  endif()
  target_link_libraries(${TEST_EXE_NAME}
    PUBLIC 
    nvqir-${NVQIR_BACKEND} nvqir  
    cudaq fmt::fmt-header-only
    cudaq-platform-default
    cudaq-builder
    gtest_main)
  if (${NVQIR_BACKEND} STREQUAL "dm")
     target_compile_definitions(${TEST_EXE_NAME} PRIVATE -DCUDAQ_BACKEND_DM)
  endif()
  gtest_discover_tests(${TEST_EXE_NAME})
endmacro()

# We will always have the QPP backend, create a tester for it
create_tests_with_backend(qpp backends/QPPTester.cpp)
create_tests_with_backend(dm "")

# FIXME Check that we have GPUs. Could be in a 
# Docker environment built with CUDA, but no --gpus flag
# or no gpus on the system. 
if (CUSTATEVEC_ROOT AND CUDA_FOUND) 
  create_tests_with_backend(custatevec "")
  
  add_executable(test_mqpu main.cpp mqpu/mqpu_tester.cpp)
  # Need to force the link to nvqir-qpp here if gcc.
  if (CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND NOT APPLE)
    target_link_options(test_mqpu PRIVATE -Wl,--no-as-needed)
  endif()
  target_link_libraries(test_mqpu
    PRIVATE 
    cudaq
    cudaq-platform-mqpu
    nvqir-custatevec
    gtest_main)
    gtest_discover_tests(test_mqpu)
endif() 

# Create an executable for SpinOp UnitTests
set(CUDAQ_SPIN_TEST_SOURCES 
   # Spin
   spin_op/SpinOpTester.cpp
)
add_executable(test_spin main.cpp ${CUDAQ_SPIN_TEST_SOURCES})
target_link_libraries(test_spin
  PRIVATE 
  cudaq-spin
  gtest_main)
gtest_discover_tests(test_spin)

add_executable(test_qpud_client main.cpp qpud_client/QPUDClientTester.cpp)
# Need to force the link to nvqir-qpp here if gcc.
if (CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND NOT APPLE)
  target_link_options(test_qpud_client PRIVATE -Wl,--no-as-needed)
endif()
target_link_libraries(test_qpud_client
  PRIVATE 
  cudaq-qpud-client
  nvqir-qpp
  gtest_main)
gtest_discover_tests(test_qpud_client)

add_subdirectory(backends)
add_subdirectory(pass)
add_subdirectory(Optimizer)
