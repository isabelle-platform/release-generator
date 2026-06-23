# Build on 22.04 (glibc 2.35) to match the deployment target. glibc is
# backward- but not forward-compatible: a binary built on a newer glibc
# (e.g. 25.04's 2.41) pulls in symbols like pidfd_spawnp@GLIBC_2.39 that
# are absent on the prod hosts, and fails to start. Keep this <= the
# oldest glibc we deploy to.
FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

RUN mkdir -p /home/root
ENV HOME="/home/root"

# Rust comes from rustup below (not apt), so the base image's Rust age is
# irrelevant — `stable` satisfies the edition2024 crates (need >= 1.85).
RUN apt-get update && \
    apt-get install -y build-essential curl git libssl-dev pkg-config python3 wget

# Rust toolchain via rustup, installed into /opt/rust so any uid (the
# Jenkins agent runs under a non-root uid) can read + execute it. The
# release script overrides CARGO_HOME at runtime to a workspace-local
# cache dir; RUSTUP_HOME stays here and is only read.
ENV RUSTUP_HOME=/opt/rust/rustup
ENV CARGO_HOME=/opt/rust/cargo
ENV PATH=/opt/rust/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable && \
    chmod -R a+rX /opt/rust

# sccache: prebuilt musl binary — no compilation needed, works under any uid.
# The cache directory is set at runtime (SCCACHE_DIR in release.sh) to a
# workspace-local path that survives between builds on the same Jenkins node.
RUN SCCACHE_VER=0.8.2 && \
    curl -fsSL "https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VER}/sccache-v${SCCACHE_VER}-x86_64-unknown-linux-musl.tar.gz" \
      | tar xz -C /tmp && \
    mv "/tmp/sccache-v${SCCACHE_VER}-x86_64-unknown-linux-musl/sccache" /usr/local/bin/sccache && \
    chmod +x /usr/local/bin/sccache
