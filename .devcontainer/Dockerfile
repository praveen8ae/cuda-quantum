# ============================================================================ #
# Copyright (c) 2022 - 2023 NVIDIA Corporation & Affiliates.                   #
# All rights reserved.                                                         #
#                                                                              #
# This source code and the accompanying materials are made available under     #
# the terms of the Apache License 2.0 which accompanies this distribution.     #
# ============================================================================ #

# To keep this image to a reasonable size, it does not contain the necessary
# CUDA dependencies to develop GPU-based components. 
# You may hence see a message along the lines of "no GPU detected" during the 
# CUDA Quantum build. Please install CUDA to enable developing these components.
FROM ghcr.io/nvidia/cuda-quantum-devdeps:gcc11
ENV PATH="${HOME}/.qoda/bin:${PATH}"
ENV PYTHONPATH="${HOME}/.qoda:${PYTHONPATH}"
ENV QODA_REPO_ROOT=/workspaces/qoda

# Getting a browser to e.g. preview docs within the container
# (seems to work more reliably/better than the extensions I've tried):
RUN apt update && apt install -y curl && export DEBIAN_FRONTEND=noninteractive \
    && curl -sSL https://dl.google.com/linux/direct/google-chrome-stable_current_$(dpkg --print-architecture).deb -o /tmp/chrome.deb \
    && apt install -y /tmp/chrome.deb

