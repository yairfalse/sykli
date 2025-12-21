#!/bin/bash
# Install sykli - CI pipelines in your language
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/yairfalse/sykli/main/install.sh | bash
#
# Or with a specific version:
#   curl -fsSL https://raw.githubusercontent.com/yairfalse/sykli/main/install.sh | bash -s v1.0.0

set -e

VERSION="${1:-latest}"
INSTALL_DIR="${SYKLI_INSTALL_DIR:-$HOME/.local/bin}"

# Detect OS and architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Linux*)  OS="linux" ;;
  Darwin*) OS="macos" ;;
  *)       echo "Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
  x86_64)  ARCH="x86_64" ;;
  aarch64) ARCH="aarch64" ;;
  arm64)   ARCH="aarch64" ;;
  *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

TARGET="${OS}-${ARCH}"

# Get download URL
if [ "$VERSION" = "latest" ]; then
  DOWNLOAD_URL="https://github.com/yairfalse/sykli/releases/latest/download/sykli-${TARGET}"
else
  DOWNLOAD_URL="https://github.com/yairfalse/sykli/releases/download/${VERSION}/sykli-${TARGET}"
fi

echo "Installing sykli for ${TARGET}..."
echo "  Version: ${VERSION}"
echo "  Install: ${INSTALL_DIR}/sykli"
echo ""

# Create install directory
mkdir -p "$INSTALL_DIR"

# Download binary
if command -v curl &> /dev/null; then
  curl -fsSL "$DOWNLOAD_URL" -o "${INSTALL_DIR}/sykli"
elif command -v wget &> /dev/null; then
  wget -q "$DOWNLOAD_URL" -O "${INSTALL_DIR}/sykli"
else
  echo "Error: curl or wget required"
  exit 1
fi

# Make executable
chmod +x "${INSTALL_DIR}/sykli"

echo "Installed sykli to ${INSTALL_DIR}/sykli"
echo ""

# Check if in PATH
if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
  echo "Add to your PATH:"
  echo "  export PATH=\"\$PATH:${INSTALL_DIR}\""
  echo ""
fi

echo "Run 'sykli --help' to get started"
