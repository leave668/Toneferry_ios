FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    clang lld llvm make python3 ca-certificates file zlib1g-dev libssl-dev curl xz-utils unzip \
    && rm -rf /var/lib/apt/lists/*
