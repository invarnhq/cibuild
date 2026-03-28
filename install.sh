#!/bin/bash
set -euo pipefail

REPO="invarnhq/cibuild"
INSTALL_DIR="/usr/local/bin"

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  ASSET="cibuild-macos-arm64.tar.gz"
  BINARY="cibuild-macos-arm64"
else
  ASSET="cibuild-macos-x64.tar.gz"
  BINARY="cibuild-macos-x64"
fi

# Get latest release tag from GitHub API
echo "Fetching latest release..."
LATEST=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' \
  | sed 's/.*"tag_name": "\(.*\)".*/\1/')

if [ -z "$LATEST" ]; then
  echo "Error: Could not determine latest release." >&2
  exit 1
fi

echo "Installing cibuild ${LATEST} (${ARCH})..."

# Download to temp dir
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "https://github.com/${REPO}/releases/download/${LATEST}/${ASSET}" \
  -o "${TMP}/${ASSET}"

# Extract
tar xzf "${TMP}/${ASSET}" -C "${TMP}"

# Install binary (use sudo if /usr/local/bin is not writable)
if [ -w "$INSTALL_DIR" ]; then
  mv "${TMP}/${BINARY}" "${INSTALL_DIR}/cibuild"
  chmod +x "${INSTALL_DIR}/cibuild"
  ln -sf "${INSTALL_DIR}/cibuild" "${INSTALL_DIR}/ci"
else
  sudo mv "${TMP}/${BINARY}" "${INSTALL_DIR}/cibuild"
  sudo chmod +x "${INSTALL_DIR}/cibuild"
  sudo ln -sf "${INSTALL_DIR}/cibuild" "${INSTALL_DIR}/ci"
fi

echo ""
echo "✓ cibuild ${LATEST} installed"
echo "  Run: cibuild --help"
echo "  Run: ci --help"
