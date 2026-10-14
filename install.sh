#!/usr/bin/env bash

set -euo pipefail

REPO="iamngoni/gitwhisper"
VERSION=${1:-"latest"}
INSTALL_DIR="/usr/local/bin"
TMP_DIR=""

cleanup() {
  if [[ -n "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

detect_os() {
  case "$(uname -s)" in
    Linux) echo "linux" ;;
    Darwin) echo "macos" ;;
    *) echo "Unsupported operating system: $(uname -s)" >&2 && exit 1 ;;
  esac
}

detect_arch() {
  local machine
  machine=$(uname -m)

  # A shell running under Rosetta reports x86_64 on Apple Silicon.
  if [[ "$1" == "macos" && "$machine" == "x86_64" ]] &&
    [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == "1" ]]; then
    machine="arm64"
  fi

  case "$machine" in
    x86_64 | amd64) echo "x64" ;;
    aarch64 | arm64) echo "arm64" ;;
    *) echo "Unsupported architecture: $machine" >&2 && exit 1 ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f1
  else
    shasum -a 256 "$1" | cut -d ' ' -f1
  fi
}

latest_version() {
  curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1
}

install_binary() {
  local os arch base asset expected actual legacy=false
  os=$(detect_os)
  arch=$(detect_arch "$os")

  if [[ "${os}-${arch}" == "macos-x64" ]]; then
    echo "There is no prebuilt GitWhisper for Intel Macs. Install it with Dart instead:" >&2
    echo "  dart pub global activate gitwhisper" >&2
    exit 1
  fi

  if [[ "$VERSION" == "latest" ]]; then
    VERSION=$(latest_version)
    if [[ -z "$VERSION" ]]; then
      echo "Could not determine the latest GitWhisper release." >&2
      exit 1
    fi
  fi

  echo "Detected platform: ${os}-${arch}"
  echo "Installing GitWhisper version: $VERSION"

  base="https://github.com/${REPO}/releases/download/${VERSION}"
  TMP_DIR=$(mktemp -d)

  asset="gitwhisper-${os}-${arch}.tar.gz"
  if ! curl -fsL -o "$TMP_DIR/$asset" "$base/$asset"; then
    # Releases up to v1.0.8 shipped one build per OS: linux was x64 and
    # macos was arm64.
    case "${os}-${arch}" in
      linux-x64 | macos-arm64)
        asset="gitwhisper-${os}.tar.gz"
        legacy=true
        ;;
      *)
        echo "GitWhisper $VERSION has no ${os}-${arch} build." >&2
        exit 1
        ;;
    esac
    curl -fsSL -o "$TMP_DIR/$asset" "$base/$asset"
  fi

  if curl -fsL -o "$TMP_DIR/$asset.sha256" "$base/$asset.sha256"; then
    expected=$(cut -d ' ' -f1 <"$TMP_DIR/$asset.sha256")
    actual=$(sha256_of "$TMP_DIR/$asset")
    if [[ "$expected" != "$actual" ]]; then
      echo "Checksum mismatch for $asset (expected $expected, got $actual)." >&2
      exit 1
    fi
    echo "Verified checksum for $asset"
  elif [[ "$legacy" == true ]]; then
    # Releases up to v1.0.8 published no checksums.
    echo "Warning: $VERSION has no published checksum for $asset; skipping verification." >&2
  else
    echo "Could not download the checksum for $asset; refusing to install an unverified binary." >&2
    exit 1
  fi

  tar -xzf "$TMP_DIR/$asset" -C "$TMP_DIR"
  chmod +x "$TMP_DIR/gitwhisper"

  sudo mkdir -p "$INSTALL_DIR"
  sudo mv "$TMP_DIR/gitwhisper" "$INSTALL_DIR/gitwhisper"
  sudo ln -sf "$INSTALL_DIR/gitwhisper" "$INSTALL_DIR/gw"

  echo "✅ Installed gitwhisper and gw to $INSTALL_DIR"
  "$INSTALL_DIR/gitwhisper" --version || true
}

install_binary
