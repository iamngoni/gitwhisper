#!/usr/bin/env bash

set -e

REPO="iamngoni/gitwhisper"
VERSION=${1:-"latest"}
BINARY_NAME="gitwhisper"

detect_platform() {
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)

  case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64 | arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH" && exit 1 ;;
  esac

  echo "${OS}-${ARCH}"
}

install_binary() {
  PLATFORM=$(detect_platform)

  echo "Detected platform: $PLATFORM"

  if [[ "$VERSION" == "latest" ]]; then
    VERSION=$(curl -s https://api.github.com/repos/$REPO/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
  fi

  echo "Installing GitWhisper version: $VERSION"

  DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/gitwhisper-${PLATFORM%%-*}.tar.gz"

  curl -L -o gitwhisper.tar.gz "$DOWNLOAD_URL"
  tar -xzf gitwhisper.tar.gz
  chmod +x gitwhisper

  sudo mv gitwhisper /usr/local/bin/gitwhisper
  sudo ln -sf /usr/local/bin/gitwhisper /usr/local/bin/gw

  echo "✅ Installed gitwhisper and gw to /usr/local/bin"
  gitwhisper --version || true
}

install_binary
