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

# Library modules to download
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
  login.sh
)

# Bundled Claude Code skills. Each entry is "<skill-name>:<file>" relative to skills/.
# `sim install-skills` later copies these into ~/.claude/skills/.
SKILL_FILES=(
  "qa-branch:SKILL.md"
)

# Stage skills next to the lib so cmd_install_skills can find them via $SIM_LIB/../skills.
SKILLS_DIR="$(dirname "$LIB_DIR")/skills"

# Remove existing target before each curl so we don't write through a symlink
# (e.g. a previous Homebrew install where /opt/homebrew/bin/sim links into the Cellar).
rm -f "$INSTALL_DIR/$SCRIPT_NAME"
curl -fsSL "${REPO}/bin/sim" -o "$INSTALL_DIR/$SCRIPT_NAME"
chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

for f in "${LIB_FILES[@]}"; do
  rm -f "$LIB_DIR/$f"
  curl -fsSL "${REPO}/lib/simclaw/$f" -o "$LIB_DIR/$f"
done

# Download shared Swift helper
rm -f "$LIB_DIR/swift/pickwindow.swift"
curl -fsSL "${REPO}/lib/simclaw/swift/pickwindow.swift" -o "$LIB_DIR/swift/pickwindow.swift"

# Stage bundled skills so `sim install-skills` can find them post-install.
rm -rf "$SKILLS_DIR"
for entry in "${SKILL_FILES[@]}"; do
  skill_name="${entry%%:*}"
  skill_file="${entry#*:}"
  mkdir -p "$SKILLS_DIR/$skill_name"
  curl -fsSL "${REPO}/skills/$skill_name/$skill_file" -o "$SKILLS_DIR/$skill_name/$skill_file"
done

echo ""
echo "sim installed to $INSTALL_DIR/$SCRIPT_NAME"
echo "Library installed to $LIB_DIR"
echo "Skills staged at $SKILLS_DIR (run 'sim install-skills' to copy into ~/.claude/skills/)"
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
