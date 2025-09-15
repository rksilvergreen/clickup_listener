# syntax=docker/dockerfile:1

# --- build stage: compile the Dart server to a native binary ---
    FROM dart:stable AS build
    WORKDIR /app
    
    # Cache dependencies
    COPY app/pubspec.* ./
    RUN dart pub get
    
    # Bring in sources
    COPY app/ ./
    RUN dart pub get --offline
    
    # Compile to a single executable
    RUN mkdir -p /build && dart compile exe lib/main.dart -o /build/clickup_listener
    
    # --- runtime stage: tiny image that only runs the binary ---
    FROM debian:bookworm-slim AS runtime
    
    # Install timezone data and set timezone to Jerusalem
    RUN apt-get update && apt-get install -y tzdata && rm -rf /var/lib/apt/lists/*
    ENV TZ=Asia/Jerusalem
    
    # add a non-root user
    RUN useradd -u 10001 -r -s /sbin/nologin appuser
    USER appuser
    
    # copy just the compiled binary
    COPY --from=build /build/clickup_listener /usr/local/bin/clickup_listener
    
    # sensible defaults; can be overridden by compose
    ENV PORT=8080 \
        CLICKUP_ENV_FILE=/runtime/env/clickup.prod.yaml
    
    EXPOSE 8080
    
    # Healthcheck (use shell so $PORT expands)
    HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
      CMD sh -lc 'curl -fsS "http://127.0.0.1:${PORT}/health" || exit 1'
    
    # start the app
    CMD ["/usr/local/bin/clickup_listener"]