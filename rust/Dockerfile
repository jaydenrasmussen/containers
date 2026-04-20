# syntax=docker/dockerfile:1

# ------------------------------------------------------------------------------
# Build Stage
# ------------------------------------------------------------------------------
ARG RUST_VERSION=latest
FROM rust:${RUST_VERSION} AS builder

WORKDIR /usr/src/app

# Install musl-tools to support static linking for scratch
RUN apt-get update && apt-get install -y musl-tools && rm -rf /var/lib/apt/lists/*
RUN rustup target add x86_64-unknown-linux-musl

# Create a dummy project to cache dependencies
RUN cargo new --bin my-app
WORKDIR /usr/src/app/my-app

# Copy manifests to cache dependencies
# Ensure you have these files in your build context
COPY Cargo.toml Cargo.lock ./

# Build dependencies only (release mode, musl target)
RUN cargo build --release --target x86_64-unknown-linux-musl

# Remove dummy source
RUN rm src/*.rs

# Copy actual source code
COPY src ./src

# Build the actual application
# 'touch' is used to force a rebuild of main.rs since the timestamp might be old from the copy
RUN touch src/main.rs
RUN cargo build --release --target x86_64-unknown-linux-musl

# ------------------------------------------------------------------------------
# Final Stage
# ------------------------------------------------------------------------------
FROM scratch

# Import user and group files from builder (optional, but good practice for non-root)
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group

# Copy the statically linked binary
# NOTE: Replace "my-app" with the actual name of your binary from Cargo.toml if different
COPY --from=builder /usr/src/app/my-app/target/x86_64-unknown-linux-musl/release/my-app /app

# Run as an unprivileged user
USER nobody:nogroup

ENTRYPOINT ["/app"]
