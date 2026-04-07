# sim

iOS Simulator interaction CLI for developers and AI agents.

Provides a single `sim` command for navigating, tapping, inspecting, and scripting the iOS Simulator — both interactively and from AI agent workflows.

Touch injection uses [WebDriverAgent](https://github.com/appium/WebDriverAgent) (UDID-scoped via XCTest + testmanagerd), so multiple simulators can be driven in parallel without window-focus conflicts.

---

## Requirements

- macOS 13+
- Xcode 15+ with Command Line Tools
- [jq](https://stedolan.github.io/jq/) (`brew install jq`)
- Simulator.app with Accessibility permission granted to Terminal/iTerm
  (System Settings → Privacy & Security → Accessibility)
- [WebDriverAgent](https://github.com/appium/WebDriverAgent) (for tap/swipe — see setup below)

---

## Install

### Homebrew (recommended)

```bash
brew tap mindvalley/sim
brew install simclaw
```

### curl (no Homebrew)

```bash
curl -fsSL https://raw.githubusercontent.com/mindvalley/homebrew-sim/main/install.sh | bash
```

---

## One-time Setup

WebDriverAgent must be cloned once per machine. `sim setup` builds it automatically on first use.

```bash
git clone https://github.com/appium/WebDriverAgent /tmp/WebDriverAgent
```

Then initialise a simulator session (boots sim, builds WDA, installs app, starts WDA, launches app):

```bash
sim --device <UDID> setup com.example.myapp
# or, if you have a .app build:
sim --device <UDID> setup /path/to/MyApp.app
```

Find your simulator UDID:

```bash
xcrun simctl list devices booted
```

---

## Usage

### For AI agents — start here

```bash
# 1. Read the current screen (includes suggested_actions for your next tap):
sim --device <UDID> layout-map

# 2. Navigate in one call (find element + tap + wait + read new screen):
sim --device <UDID> tap-and-wait "Sign In" "Home" 10

# 3. Chain commands into one Bash call to avoid API round-trip overhead:
sim --device <UDID> tap-and-wait "Library" "Library" 8 && \
sim --device <UDID> tap-and-wait "View All" "All Programs" 8
```

### Common commands

```bash
sim [--device <UDID>] layout-map                        # full screen snapshot (recommended first call)
sim [--device <UDID>] tap-and-wait <label> [wait] [s]   # find + tap + wait + read (1 call)
sim [--device <UDID>] tap <x> <y>                       # tap at iOS logical coordinates
sim [--device <UDID>] tap-element "Label"               # tap by accessibility label
sim [--device <UDID>] swipe <x1> <y1> <x2> <y2>        # swipe
sim [--device <UDID>] scroll-up                         # scroll up
sim [--device <UDID>] scroll-down                       # scroll down
sim [--device <UDID>] scroll-to-visible "Label"         # scroll until element is visible
sim [--device <UDID>] wait-for "Label" [timeout]        # block until element appears
sim [--device <UDID>] find-element "Label"              # find element → JSON
sim [--device <UDID>] describe-point <x> <y>            # hit-test element at coordinate
sim [--device <UDID>] screenshot output.png             # capture screen
sim [--device <UDID>] type "text"                       # type into focused field
sim [--device <UDID>] status                            # device info + screen bounds
```

Without `--device`, targets the most recently booted simulator.

### Parallel simulators

Each simulator needs its own WDA port:

```bash
sim --device <UDID1> setup com.example.myapp --port 8100
sim --device <UDID2> setup com.example.myapp --port 8101
# Taps to each are fully independent — no global queue needed
```

---

## layout-map output

`layout-map` is the primary read command. It returns a single JSON snapshot:

```json
{
  "screen": "Account",
  "modal": false,
  "navigation": {
    "title": "Account",
    "back": { "label": "icoBack", "x": 27, "y": 76 },
    "tabs": [
      { "label": "Today", "x": 39, "y": 795, "selected": true }
    ]
  },
  "interactive": [
    { "role": "AXButton", "label": "View Profile", "x": 33, "y": 234, "w": 121, "h": 40, "enabled": true }
  ],
  "content": {
    "headings": [],
    "texts": ["Justin Champappilly", "2", "DAY STREAK"]
  },
  "scroll": {
    "vertical": true,
    "horizontal": false,
    "above_fold": [],
    "below_fold": ["Library", "Favorites", "Downloads"]
  },
  "context": "tab_screen",
  "suggested_actions": [
    "tap 'View Profile' at (93, 254)",
    "tap tab 'Library' at (196, 795)",
    "scroll down to reveal: Library, Favorites, Downloads"
  ]
}
```

**Coordinate note:** `interactive` elements have top-left `x,y`. Tap center = `x + w/2, y + h/2`.  
`navigation.tabs` and `navigation.back` have center coordinates.

---

## Agent integration (Claude Code)

Add to your `~/.claude/settings.json` allowlist so the tool runs without prompting:

```json
{
  "permissions": {
    "allow": [
      "/opt/homebrew/bin/sim",
      "/usr/local/bin/sim"
    ]
  }
}
```

---

## Performance tips

Each separate Bash tool call from an AI agent costs ~10s of API round-trip overhead on top of the ~1–2s the command itself takes. Batch sequential calls with `&&`:

```bash
# Good — 1 tool call instead of 4:
sim --device <UDID> tap-and-wait "Sign In" "Home" 10 && \
sim --device <UDID> tap-and-wait "View Profile" "Profile" 8
```

---

## Releasing a new version

1. Update `bin/sim` with your changes.
2. Commit and push to `main`.
3. Tag the release: `git tag v1.x.x && git push origin v1.x.x`
4. GitHub will auto-create a tarball at `…/archive/refs/tags/v1.x.x.tar.gz`.
5. Update `Formula/sim.rb`:
   - Set `url` to the new tarball URL.
   - Set `sha256` to the output of: `curl -sL <tarball_url> | sha256sum`
   - Bump `version`.
6. Commit the formula update and push.

---

## License

MIT
