# syntax=docker/dockerfile:1.7
ARG CONTROLLER_BASE_IMAGE_REF

FROM scratch AS os-input
COPY versions.env /versions.env
COPY locks/apt-*.lock /locks/
COPY scripts/install-os.sh /scripts/install-os.sh

FROM scratch AS language-input
COPY versions.env /versions.env
COPY locks/downloads-*.json /locks/
COPY scripts/install-common.sh scripts/install-languages.sh /scripts/

FROM scratch AS package-input
COPY versions.env /versions.env
COPY locks/downloads-*.json locks/python-oci.lock /locks/
COPY build/npm /build/npm
COPY scripts/install-common.sh scripts/install-packages.sh /scripts/

FROM scratch AS descriptor-input
COPY versions.env /versions.env
COPY build/layout.json /build/layout.json
COPY scripts/finalize-image.sh /scripts/finalize-image.sh

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
RUN --mount=from=package-input,target=/build-input,readonly \
    --mount=type=tmpfs,target=/home/multica/agents \
    --mount=type=cache,id=multica-runtime-downloads,target=/var/cache/multica-downloads,sharing=locked \
    /bin/bash /build-input/scripts/install-packages.sh
ENV PATH="/opt/multica/tools/bin:/opt/multica/tools/node/bin:/opt/multica/tools/php/bin:/opt/multica/tools/rust/bin:/opt/multica/tools/providers/node_modules/.bin:/opt/multica/tools/oci/bin:/opt/multica/tools/google-cloud-sdk/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOME=/home/multica/agents \
    GOTOOLCHAIN=local \
    CLOUDSDK_PYTHON=/usr/bin/python3 \
    CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK=1 \
    CLOUDSDK_CORE_DISABLE_USAGE_REPORTING=true \
    PI_TELEMETRY=0

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
ENTRYPOINT ["/opt/multica/controller/runtime"]
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
