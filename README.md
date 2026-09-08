# Multica Runtime

공식 Multica CLI와 작업용 개발 도구를 설치하는 완성 이미지입니다. `multica-runtime-controller`의 ABI 2 베이스를 상속합니다. 베이스는 Go SDK와 controller/shim을 제공하고, 이 저장소는 공식 daemon과 실제 Codex/Pi, 언어, CLI, 확장을 소유합니다.

최종 이미지는 UID/GID `65532:65532`와 읽기 전용 rootfs에서 실행합니다. Kubernetes 시작 시 패키지를 설치하지 않습니다. Helm에는 완성 이미지 하나를 입력하며 기본값은 `ghcr.io/korioinc/multica-runtime:latest`입니다. 실행 중인 controller는 실제 image digest와 플랫폼을 고정하고 worker/init에도 같은 참조를 사용합니다. `latest` 변경은 기존 Pod를 자동 교체하지 않습니다.

## 로컬 빌드와 검증

필요 도구는 Docker Buildx, Bash, jq, curl, OpenSSL, UUID 생성기와 matching controller checkout입니다. 모든 자동화는 `.sh`로 구현합니다. 설치·native 검증에서 Go/PHP/Python 등 실제 도구를 실행하지만 별도의 Go/Python 스크립트 래퍼를 두지 않습니다.

아직 ABI 2 production base digest가 발행되지 않아 `versions.env`의 `CONTROLLER_BASE_IMAGE_REF`는 비어 있습니다. Production build와 release는 이 상태를 거부합니다. 아래처럼 같은 workspace의 실제 로컬 베이스를 명시하면 GHCR 발행에 의존하지 않고 개발할 수 있습니다.

```bash
controller=../multica-runtime-controller
platform=linux/arm64 # Docker 호스트가 amd64이면 linux/amd64
docker buildx build --load --platform "$platform" \
  --build-arg "GO_VERSION=$(sed -n 's/^GO_VERSION=//p' "$controller/build/runtime-versions.env")" \
  --build-arg VERSION=dev \
  --build-arg "COMMIT=$(git -C "$controller" rev-parse HEAD)" \
  --tag multica-runtime-controller:local "$controller"
scripts/build-image.sh --image multica-runtime:local \
  --controller-source "$controller" \
  --base-image multica-runtime-controller:local --platform "$platform"
scripts/verify-image.sh --image multica-runtime:local \
  --controller-source "$controller"
```

`--image`와 `--controller-source`는 필수입니다. 검증은 지정 checkout으로 controller 바이너리를 다시 빌드하여 베이스의 실제 SHA-256과 비교합니다. Controller 소스가 바뀌면 베이스도 다시 만들어야 합니다. `--base-image`는 로컬 개발용 명시 입력이며 production pin을 변경하지 않습니다. Production은 `CONTROLLER_BASE_IMAGE_REF=repository@sha256:...`를 채운 뒤 `--base-image` 없이 빌드합니다.

`--target installed`와 `--target prepared`는 설치 문제 조사에만 사용하는 중간 stage입니다. 배포 가능한 최종 이미지가 아닙니다. 매 빌드는 플랫폼별 새 imageBuildID를 만들고 descriptor/OCI label에 동일하게 기록합니다. Prepared stage의 설치 파일과 descriptor를 확정한 뒤 matching source의 실제 adapter fixture를 실행합니다. Final stage에는 그 검증 기록만 추가하며 fixture 코드·합성 설정·인증을 복사하지 않습니다.

빌드의 모든 root RUN은 shell 시작 전부터 HOME를 임시 mount로 격리합니다. Installer와 에뮬레이터의 시작 cache가 최종 UID 65532 HOME에 남지 않도록 하며, 패키지 installer의 HOME/cache도 별도 private 경로에서 폐기합니다.

`verify-image.sh`는 이미지 자체를 변경하지 않고 다음을 확인합니다.

- UID/GID, imageBuildID/label, descriptor·controller·CLI/provider의 hash와 검증 기록.
- 실제 도구 시작, PHP 세 확장의 ABI·API, Rust/Go compile/run, Python venv.
- fresh private HOME, tmp/run과 읽기 전용 설치 prefix.
- 실제 공식 daemon의 탐색·등록·모델/RPC 및 controller adapter의 로컬 HTTP/WS fixture.

네트워크 없는 도구 검증과 matching Go module build/loopback adapter 검증을 분리합니다. 실제 모델 생성이나 클라우드 계정·운영자 인증 파일은 사용하지 않습니다. 로컬 개발에서는 현재 Docker 호스트의 아키텍처 하나만 검증합니다. amd64/arm64 이미지의 빌드와 native 검증은 GitHub Actions release matrix가 담당합니다. Docker 호스트와 이미지 아키텍처가 다르면 기본적으로 거부하며, 명시적인 `--allow-emulation` 결과는 **emulated**로 구분합니다. 실제 Kubernetes의 fsGroup/subPath/PVC 검증은 controller 저장소의 disposable K3s harness에서 로컬 호스트 아키텍처 하나로 수행합니다.

## 버전과 설치 잠금

직접 버전의 단일 원본은 [versions.env](versions.env)입니다. Go는 베이스 소유이므로 별도 `GO_VERSION`을 선언하거나 다시 설치하지 않습니다. Runtime의 [VERSION](VERSION)은 controller 버전과 독립적입니다.

| 범위 | 설치 도구 | 잠금 |
|---|---|---|
| JavaScript | Node, Corepack | 아키텍처별 SHA-256, npm lock |
| PHP | PHP, Composer, MongoDB/Redis/zstd 확장 | 소스/배포물 SHA-256, 동일 phpize/php-config로 빌드 |
| Rust/Python | rustc, cargo, linker, Python, uv, pipx | Rust/uv 배포물 SHA-256, Debian snapshot/package lock |
| Git/일반 도구 | git, git-lfs, AVH git-flow, gh, curl, grep, coreutils, vim, tree, lefthook | Debian lock 또는 배포물 SHA-256 |
| 데이터/shell | jq, Mike Farah yq, shellcheck, shfmt | Debian lock 또는 배포물 SHA-256 |
| 문서/미디어 | ffmpeg, ImageMagick, Poppler, Pandoc | Debian lock |
| Kubernetes/cloud | k9s, kubectx/kubens, kubectl, AWS CLI v2, OCI CLI, gcloud | 배포물 SHA-256, OCI 전용 venv와 Python transitive hash lock |
| AI/MCP | Multica, Codex, Pi, codebase-memory-mcp, chrome-devtools-mcp | 배포물 SHA-256, npm transitive integrity |

`locks/downloads-{amd64,arm64}.json`, `locks/apt-{amd64,arm64}.lock`, `locks/python-oci.lock`, `build/npm/*/package-lock.json`을 함께 유지합니다. Final image의 `/opt/multica/runtime/inventory`에는 실제 Debian 패키지 inventory와 사용한 버전/잠금이 있습니다. 설치 prefix는 `/opt/multica/tools`이고 이미지 빌드 이후 바뀌지 않습니다.

```bash
scripts/inputs.sh check
scripts/lock-downloads.sh                 # 명시한 버전의 배포물 checksum 갱신
scripts/lock-npm.sh --refresh             # 직접 버전과 전체 npm lock 갱신
scripts/lock-npm.sh --complete-integrity  # 기존 exact tarball의 누락 integrity 보충
scripts/lock-apt.sh --resolver-image IMAGE@sha256:DIGEST --arch arm64
uv pip compile build/python/oci.in --python-version 3.11 --universal \
  --generate-hashes --output-file locks/python-oci.lock
```

`versions.env`는 검증한 literal assignment만 읽습니다. Shell code와 인증 값을 넣지 않습니다. 버전/lock이 일치하지 않으면 빌드는 실패합니다. Lock 갱신 후 로컬 호스트의 한 플랫폼을 검증하고, 발행 시에는 CI에서 두 플랫폼의 이미지 검증을 통과해야 합니다.

공식 daemon adapter 계약 ID `multica-v0.4.40-v1`은 검증 baseline을 나타냅니다. CLI pin을 바꿀 때마다 실제 matching-source adapter suite와 native 검증을 통과해야 final image가 만들어집니다. 다른 버전의 호환성을 버전 문자열만으로 가정하지 않습니다.

## Provider 설정과 내장 Pi 패키지

사용자 settings/auth/models/MCP 파일을 이미지에 넣지 않습니다. Terraform의 운영자 소유 ConfigMap을 chart가 private HOME으로 복사하며, 운영자 파일이 image seed보다 우선합니다. Seed에는 CBM의 공개 `auto_index` 설정만 있습니다. 최초 확정한 configuration bundle/snapshot은 같은 controller의 worker가 공유하고, 실행 중 HOME 수정은 각 Pod에만 남습니다.

Pi settings의 `packages`에는 아래 **절대 경로**를 사용합니다. 모든 패키지는 버전과 transitive integrity를 잠갔습니다.

```text
/opt/multica/tools/pi-packages/node_modules/pi-mcp-adapter
/opt/multica/tools/pi-packages/node_modules/pi-thinking-level
/opt/multica/tools/pi-packages/node_modules/pi-web-access
/opt/multica/tools/pi-packages/node_modules/pi-openai-service-tier
/opt/multica/tools/pi-packages/node_modules/@dietrichgebert/ponytail
/opt/multica/tools/pi-packages/node_modules/pi-cache-optimizer
```

MCP 서버 command는 `/opt/multica/tools/bin/codebase-memory-mcp`와 `/opt/multica/tools/providers/node_modules/.bin/chrome-devtools-mcp`를 사용합니다. Floating `npx` launcher는 필요하지 않습니다. 서버 연결 옵션과 대상 선택은 운영자 설정이 소유합니다. 다른 Pi 확장/MCP를 사용하려면 custom image에 의존성을 먼저 설치합니다. Chrome 브라우저는 포함하지 않으며 이미지 검증은 브라우저를 제어하지 않는 MCP handshake/tool-list와 로컬 fixture로 제한합니다.

HOME는 `/home/multica/agents`, tmp는 `/tmp`, run은 `/run/multica`입니다. 세 위치는 Pod별 UID 65532 소유의 `0700` child입니다. Go/npm/Corepack/Cargo/uv/pipx/cloud/CBM cache와 IPC도 private HOME 아래에 둡니다. Descriptor의 `env`는 controller가 실제 실행 HOME에 맞추어 확장합니다. 코드·도구 prefix나 다른 task의 workspace를 writable volume으로 덮지 않습니다.

## 자동 발행

[release.yml](.github/workflows/release.yml)은 main push에서 독립 VERSION/revision을 검증하고, amd64/arm64 native runner에서 같은 과정을 실행합니다. 검증을 통과한 candidate digest 두 개만 version index와 latest의 대상입니다. 이미지 안의 검증 기록 때문에 prepared→verify→final 순서가 필요하며, final 외부 검증에서는 artifact를 다시 빌드하지 않습니다.

재실행은 같은 revision/platform의 기존 candidate를 검사한 뒤 동일 bytes를 재사용합니다. 다른 revision의 중복 VERSION, 부족한 native 결과, 검증 실패, 중복 플랫폼 index, 더 새로운 main/latest는 발행 또는 승격을 차단합니다. Registry/GitHub 경계는 PATH로 로컬 stub을 주입하여 `scripts/verify-release.sh`에서 검증합니다. 실행 중인 chart/image 값을 갱신하는 updater는 없습니다. 이 저장소를 로컬에서 구현·검증하는 작업은 실제 GHCR/GitHub 발행을 수행하지 않습니다.
