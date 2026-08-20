#!/usr/bin/env bash
#
# Install the kubeconform static binary. Shared by the argocd-rendering-check
# reusable workflow and this repo's own self-test so the two cannot drift to
# different tools or versions.
#
# Usage: install-kubeconform.sh [version]
#   version              defaults to 0.6.7 (no leading v)
#   KUBECONFORM_INSTALL_DIR  target directory (default ~/.local/bin)
#
# Appends the target directory to $GITHUB_PATH when running under Actions.
set -euo pipefail

VERSION="${1:-0.6.7}"
DIR="${KUBECONFORM_INSTALL_DIR:-$HOME/.local/bin}"

if command -v kubeconform >/dev/null 2>&1 \
  && [ "$(kubeconform -v 2>/dev/null)" = "v${VERSION}" ]; then
  echo "kubeconform v${VERSION} already installed"
  exit 0
fi

case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "FATAL: unsupported architecture $(uname -m)" >&2; exit 2 ;;
esac

mkdir -p "$DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -sSfL \
  "https://github.com/yannh/kubeconform/releases/download/v${VERSION}/kubeconform-linux-${arch}.tar.gz" \
  -o "$tmp/kubeconform.tar.gz"
tar -xzf "$tmp/kubeconform.tar.gz" -C "$tmp" kubeconform
install -m 0755 "$tmp/kubeconform" "$DIR/kubeconform"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$DIR" >> "$GITHUB_PATH"
fi
"$DIR/kubeconform" -v
