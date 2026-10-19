# Local builder image: upstream FastFlowLM's own CI build environment plus what its CI
# installs on top in every run (Rust toolchain, libedit-dev), baked in once.
# Used by the Makefile; CI uses the upstream image directly, as upstream does.
ARG BASE
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive \
    RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo \
    PATH=/opt/rust/cargo/bin:$PATH
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates libedit-dev \
 && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable \
 && chmod -R a+rwX /opt/rust \
 && rm -rf /var/lib/apt/lists/*
