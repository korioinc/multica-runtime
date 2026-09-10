# AGENTS.md

## Public Image Security

- This image is public and can be downloaded by anyone. Never include secrets, credentials, private keys, sensitive internal data, or any other content that could create a security risk in the image.

## Tool Downloads

- Use pinned tool versions and official HTTPS download URLs.
- Keep tool installers free of manually maintained SHA256 checksum files and custom checksum verification steps.

## Docker Build Structure

- Order installation layers to maximize cache reuse. Place expensive, infrequently changed OS and language installations first, followed by frequently updated agent packages and runtime configuration.
- Give each installation layer only the versions, package lists, and scripts it consumes. Keep the full source tree, full `versions.env`, and runtime configuration outside installation inputs.
- Use separate inputs and installation layers for independent tool groups so their changes preserve existing language build caches.
- Reuse BuildKit cache mounts for APT packages and downloaded artifacts.
- Add build UUIDs, release versions, and commit metadata after installation layers.
- Use separate external BuildKit caches for each architecture in CI, importing previous caches and exporting with `mode=max`. Keep cache tags separate from release image tags.
