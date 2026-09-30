# arm64 is a developer platform, built only natively

Every published image includes `linux/arm64` even though nothing deploys on it (the AKS node pool is amd64-only): developers run images on Apple Silicon, and knkcms/deploy's `make images-pull` loads `:latest` into arm64 k3d nodes that cannot execute amd64 binaries. arm64 is therefore kept, but may only be produced by a native build — a cross-compiling Dockerfile (`FROM --platform=$BUILDPLATFORM`) or a native ARM runner — never under QEMU. In September 2026 emulated arm64 builds (`RUN npm ci` under QEMU) hung to the 6-hour job limit seven times, burning ~2,500 minutes and exhausting both orgs' Actions quota.

## Considered Options

- **Drop arm64** — cheapest, but breaks the local k3d loop with `exec format error`.
- **Keep QEMU with a timeout** — bounds the damage but still ~20 min per merge for nothing a deployment uses.
