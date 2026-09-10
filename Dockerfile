# syntax=docker/dockerfile:1.7
ARG CONTROLLER_BASE_IMAGE_REF

FROM scratch AS version-input
COPY versions.env /versions.env
COPY scripts/lib.sh scripts/project-inputs.sh /scripts/

FROM ${CONTROLLER_BASE_IMAGE_REF} AS projected-input
USER 0:0
RUN --mount=from=version-input,target=/build-input,readonly \
    --mount=type=tmpfs,target=/home/multica/agents \
    /bin/bash /build-input/scripts/project-inputs.sh /projected-input

FROM scratch AS os-input
COPY --from=projected-input /projected-input/os/versions.env /versions.env
COPY build/apt-packages.txt /build/apt-packages.txt
COPY scripts/install-os.sh /scripts/install-os.sh

FROM scratch AS language-input
COPY --from=projected-input /projected-input/languages/versions.env /versions.env
COPY scripts/lib.sh scripts/downloads.sh scripts/install-common.sh scripts/install-languages.sh /scripts/

FROM scratch AS tools-input
COPY --from=projected-input /projected-input/tools/versions.env /versions.env
COPY scripts/lib.sh scripts/downloads.sh scripts/install-common.sh scripts/install-tools.sh /scripts/

FROM scratch AS agents-input
COPY --from=projected-input /projected-input/agents/versions.env /versions.env
COPY scripts/lib.sh scripts/downloads.sh scripts/install-common.sh scripts/install-agents.sh /scripts/

FROM scratch AS descriptor-input
COPY versions.env /versions.env
COPY build/layout.json /build/layout.json
COPY scripts/finalize-image.sh /scripts/

FROM scratch AS desktop-input
COPY --from=projected-input /projected-input/desktop/versions.env /versions.env
COPY build/desktop-apt-packages.txt /build/
COPY scripts/lib.sh scripts/downloads.sh scripts/install-common.sh scripts/install-desktop.sh /scripts/

FROM scratch AS database-input
COPY --from=projected-input /projected-input/database/versions.env /versions.env
COPY scripts/lib.sh scripts/install-database-clients.sh /scripts/

FROM scratch AS runtime-config-input
COPY build/layout.json build/desktop-supervisord.conf /build/
COPY scripts/render-path-profile.sh scripts/runtime-entrypoint.sh scripts/configure-chrome.sh /scripts/

FROM scratch AS verification-input
COPY scripts/verify-source.sh scripts/verify-native.sh scripts/verify-adapter.sh scripts/verify-providers.sh /scripts/

FROM ${CONTROLLER_BASE_IMAGE_REF} AS installed
USER 0:0
ARG TARGETARCH
# Installers and translated shells receive a temporary HOME before execution.
# Their caches never enter the inherited UID 65532 HOME in image layers.
RUN --mount=from=os-input,target=/build-input,readonly \
    --mount=type=tmpfs,target=/home/multica/agents \
    --mount=type=cache,id=multica-runtime-apt-$TARGETARCH,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=multica-runtime-apt-lists-$TARGETARCH,target=/var/lib/apt/lists,sharing=locked \
    /bin/sh /build-input/scripts/install-os.sh
RUN --mount=from=language-input,target=/build-input,readonly \
    --mount=type=tmpfs,target=/home/multica/agents \
    --mount=type=cache,id=multica-runtime-downloads,target=/var/cache/multica-downloads,sharing=locked \
    /bin/bash /build-input/scripts/install-languages.sh
# Stable general, desktop and database tools precede frequently updated agents.
# Keep their inputs separate so a CLI pin does not reinstall these dependencies.
RUN --mount=from=tools-input,target=/build-input,readonly \
    --mount=type=tmpfs,target=/home/multica/agents \
    --mount=type=cache,id=multica-runtime-downloads,target=/var/cache/multica-downloads,sharing=locked \
    /bin/bash /build-input/scripts/install-tools.sh
RUN --mount=from=desktop-input,target=/build-input,readonly \
    --mount=type=tmpfs,target=/home/multica/agents \
    --mount=type=cache,id=multica-runtime-apt-$TARGETARCH,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=multica-runtime-apt-lists-$TARGETARCH,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,id=multica-runtime-downloads,target=/var/cache/multica-downloads,sharing=locked \
    /bin/bash /build-input/scripts/install-desktop.sh
RUN --mount=from=database-input,target=/build-input,readonly \
    --mount=type=tmpfs,target=/home/multica/agents \
    --mount=type=cache,id=multica-runtime-apt-$TARGETARCH,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=multica-runtime-apt-lists-$TARGETARCH,target=/var/lib/apt/lists,sharing=locked \
    /bin/bash /build-input/scripts/install-database-clients.sh
RUN --mount=from=agents-input,target=/build-input,readonly \
    --mount=type=tmpfs,target=/home/multica/agents \
    --mount=type=cache,id=multica-runtime-downloads,target=/var/cache/multica-downloads,sharing=locked \
    /bin/bash /build-input/scripts/install-agents.sh
# Login shells reset ENV PATH via /etc/profile, including agent tool calls in
# task-worker Pods. Install outside HOME and independently of the entrypoint.
# Runtime configuration has no version input and never invalidates installers.
RUN --mount=from=runtime-config-input,target=/build-input,readonly \
    --mount=type=tmpfs,target=/home/multica/agents \
    mkdir -p /etc/profile.d /etc/multica /opt/multica/runtime && \
    install -m 0555 /build-input/scripts/runtime-entrypoint.sh /opt/multica/runtime/entrypoint && \
    install -m 0444 /build-input/build/desktop-supervisord.conf /etc/multica/desktop-supervisord.conf && \
    /bin/bash /build-input/scripts/render-path-profile.sh /build-input/build/layout.json > /etc/profile.d/10-multica-path.sh && \
    chmod 0644 /etc/profile.d/10-multica-path.sh && \
    /bin/bash /build-input/scripts/configure-chrome.sh
ENV PATH="/opt/multica/tools/bin:/opt/multica/tools/node/bin:/opt/multica/tools/php/bin:/opt/multica/tools/rust/bin:/opt/multica/tools/providers/node_modules/.bin:/opt/multica/tools/google-cloud-sdk/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOME=/home/multica/agents \
    GOTOOLCHAIN=local \
    CLOUDSDK_PYTHON=/usr/bin/python3 \
    CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK=1 \
    CLOUDSDK_CORE_DISABLE_USAGE_REPORTING=true \
    PI_TELEMETRY=0 \
    DISPLAY=:99 \
    MULTICA_DESKTOP_SCREEN=2560x1440x24 \
    XDG_RUNTIME_DIR=/tmp/multica-desktop \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/multica-desktop/bus" \
    XAUTHORITY=/tmp/multica-desktop/Xauthority \
    XDG_SESSION_TYPE=x11 \
    GDK_BACKEND=x11 \
    NO_AT_BRIDGE=0

FROM installed AS prepared
ARG CONTROLLER_BASE_IMAGE_REF
ARG IMAGE_BUILD_ID
ARG TARGETOS
ARG TARGETARCH
ARG VERSION
ARG COMMIT
RUN --mount=from=descriptor-input,target=/build-input,readonly \
    --mount=type=tmpfs,target=/home/multica/agents \
    /bin/bash /build-input/scripts/finalize-image.sh /build-input "$IMAGE_BUILD_ID" "$TARGETOS/$TARGETARCH"
LABEL org.opencontainers.image.title="Multica Runtime" \
      org.opencontainers.image.source="https://github.com/korioinc/multica-runtime" \
      org.opencontainers.image.base.name="${CONTROLLER_BASE_IMAGE_REF}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}" \
      io.multica.image-build-id="${IMAGE_BUILD_ID}" \
      io.multica.controller-abi="2"
USER 65532:65532
ENTRYPOINT ["/opt/multica/runtime/entrypoint"]
CMD ["controller"]

FROM prepared AS adapter-verify
USER 0:0
RUN --mount=type=tmpfs,target=/home/multica/agents \
    mkdir -p /out /workspace && chown 65532:65532 /out /workspace /tmp && chmod 0700 /out /workspace /tmp
USER 65532:65532
RUN --mount=from=controller-source,source=src,target=/controller-source/src,readonly \
    --mount=from=verification-input,target=/verify-input,readonly \
    /bin/bash /verify-input/scripts/verify-native.sh && \
    /bin/bash /verify-input/scripts/verify-adapter.sh /controller-source /out/verification.json

FROM prepared AS final
COPY --from=adapter-verify --chown=0:0 --chmod=0444 /out/verification.json /opt/multica/runtime/verification.json
