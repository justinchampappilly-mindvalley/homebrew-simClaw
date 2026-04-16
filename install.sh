#!/bin/bash
# install.sh — curl-based installer for sim (fallback if Homebrew is not available)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/justinchampappilly-mindvalley/homebrew-simClaw/main/install.sh | bash
#
# What it does:
#   1. Installs jq if missing (requires Homebrew)
#   2. Downloads sim and its library modules
#   3. Makes it executable

set -euo pipefail

REPO="https://raw.githubusercontent.com/justinchampappilly-mindvalley/homebrew-simClaw/main"
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

# Determine library directory (sibling to bin)
LIB_DIR="$(dirname "$INSTALL_DIR")/lib/simclaw"
mkdir -p "$LIB_DIR/swift"

echo "==> Installing sim to $INSTALL_DIR/$SCRIPT_NAME"
echo "==> Installing library to $LIB_DIR"

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

# Download the main script
curl -fsSL "${REPO}/bin/sim" -o "$INSTALL_DIR/$SCRIPT_NAME"
chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

# Download library modules
LIB_FILES=(
  core.sh
  device.sh
  coords.sh
  bootstrap.sh
  wda.sh
  layout_map.sh
  inspect.sh
  wait.sh
  nav.sh
  touch.sh
  setup.sh
  type.sh
  misc.sh
)

for f in "${LIB_FILES[@]}"; do
  curl -fsSL "${REPO}/lib/simclaw/$f" -o "$LIB_DIR/$f"
done

# Download shared Swift helper
curl -fsSL "${REPO}/lib/simclaw/swift/pickwindow.swift" -o "$LIB_DIR/swift/pickwindow.swift"

echo ""
echo "sim installed to $INSTALL_DIR/$SCRIPT_NAME"
echo "Library installed to $LIB_DIR"
echo ""
echo "Next steps:"
echo "  1. Clone WebDriverAgent (one-time):"
echo "       git clone https://github.com/appium/WebDriverAgent /tmp/WebDriverAgent"
echo "  2. Start a session:"
echo "       sim --device <UDID> setup <bundle_id>"
echo "  3. Navigate:"
echo "       sim --device <UDID> layout-map"
echo ""
echo "See https://github.com/justinchampappilly-mindvalley/homebrew-simClaw for full documentation."
