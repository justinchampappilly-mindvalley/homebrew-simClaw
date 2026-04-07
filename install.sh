#!/bin/bash
# install.sh — curl-based installer for sim (fallback if Homebrew is not available)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mindvalley/simclaw/main/install.sh | bash
#
# What it does:
#   1. Installs jq if missing (requires Homebrew)
#   2. Copies sim to /usr/local/bin/sim (or /opt/homebrew/bin/sim on Apple Silicon)
#   3. Makes it executable

set -euo pipefail

REPO="https://raw.githubusercontent.com/mindvalley/simclaw/main"
SCRIPT_NAME="sim"

# Determine install directory
if [[ -d "/opt/homebrew/bin" ]]; then
  INSTALL_DIR="/opt/homebrew/bin"
elif [[ -d "/usr/local/bin" ]]; then
  INSTALL_DIR="/usr/local/bin"
else
  INSTALL_DIR="$HOME/.local/bin"
  mkdir -p "$INSTALL_DIR"
fi

echo "==> Installing sim to $INSTALL_DIR/$SCRIPT_NAME"

# Check for jq
if ! command -v jq &>/dev/null; then
  if command -v brew &>/dev/null; then
    echo "==> Installing jq (required dependency)..."
    brew install jq
  else
    echo "ERROR: jq is required but not installed."
    echo "Install it with: brew install jq"
    exit 1
  fi
fi

# Download the script
curl -fsSL "${REPO}/bin/sim" -o "$INSTALL_DIR/$SCRIPT_NAME"
chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

echo ""
echo "sim installed to $INSTALL_DIR/$SCRIPT_NAME"
echo ""
echo "Next steps:"
echo "  1. Clone WebDriverAgent (one-time):"
echo "       git clone https://github.com/appium/WebDriverAgent /tmp/WebDriverAgent"
echo "  2. Start a session:"
echo "       sim --device <UDID> setup <bundle_id>"
echo "  3. Navigate:"
echo "       sim --device <UDID> layout-map"
echo ""
echo "See https://github.com/mindvalley/simclaw for full documentation."
