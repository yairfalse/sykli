# Build stage - compile escript
FROM elixir:1.15-slim AS builder

WORKDIR /app
COPY core/ ./

RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    mix escript.build

# Runtime stage
FROM elixir:1.15-slim

# Install Go and Rust for SDK support
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Go
RUN curl -fsSL https://go.dev/dl/go1.21.5.linux-amd64.tar.gz | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:${PATH}"

# Install Rust to a portable location with minimal profile
ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --default-toolchain stable --profile minimal -y
ENV PATH="${CARGO_HOME}/bin:${PATH}"

# Copy escript from builder
COPY --from=builder /app/sykli /usr/local/bin/sykli

# Entrypoint runs sykli with provided path
ENTRYPOINT ["/usr/local/bin/sykli"]
