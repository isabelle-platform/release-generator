FROM ubuntu:25.04

ARG DEBIAN_FRONTEND=noninteractive

RUN mkdir -p /home/root
ENV HOME="/home/root"

# Note: no `cargo` from apt — Ubuntu 25.04 ships Rust 1.84, too old for
# the `edition2024` crates in the dependency tree (need >= 1.85).
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
