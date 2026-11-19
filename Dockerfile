FROM debian:bookworm-slim AS godot-build
ARG GODOT_VERSION=4.6.3
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    base="https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION}-stable"; \
    curl -fSL --retry 3 "$base/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" -o /tmp/godot.zip; \
    unzip -p /tmp/godot.zip "Godot_v${GODOT_VERSION}-stable_linux.x86_64" >/usr/local/bin/godot; \
    chmod +x /usr/local/bin/godot; \
    curl -fSL --retry 3 "$base/Godot_v${GODOT_VERSION}-stable_export_templates.tpz" -o /tmp/templates.tpz; \
    mkdir -p "/root/.local/share/godot/export_templates/${GODOT_VERSION}.stable"; \
    unzip -j /tmp/templates.tpz templates/web_nothreads_release.zip templates/web_nothreads_debug.zip -d "/root/.local/share/godot/export_templates/${GODOT_VERSION}.stable"; \
    rm /tmp/godot.zip /tmp/templates.tpz
WORKDIR /app
COPY . .
RUN mkdir -p build/web \
    && godot --headless --editor --import --quit \
    && godot --headless --export-release Web build/web/index.html \
    && test -s build/web/index.wasm \
    && rm -rf tests

FROM node:24-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=godot-build /usr/local/bin/godot /usr/local/bin/godot
COPY --from=godot-build /app /app
ENV GODOT_SILENCE_ROOT_WARNING=1
ENTRYPOINT ["node", "deploy/server.mjs"]
