# Stage 1: Build standalone Dart executable
FROM dart:stable AS build

WORKDIR /app

# Copy pubspec files first for layer caching
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

# Copy repository source and compile binary
COPY . .
RUN dart compile exe bin/relay.dart -o bin/relay

# Stage 2: Production runtime container
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/bin/relay /app/relay

# Run as non-root user
RUN useradd -m -u 10001 remotex
USER remotex

ENV REMOTEX_RELAY_HOST=0.0.0.0
ENV REMOTEX_RELAY_PORT=8080
ENV REMOTEX_ENV=production

EXPOSE 8080

ENTRYPOINT ["/app/relay"]
