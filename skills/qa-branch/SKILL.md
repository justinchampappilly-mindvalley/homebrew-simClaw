---
name: qa-branch
description: "TRIGGER on: \"test this PR\", \"QA this PR\", \"run QA on PR\", \"test the changes in PR\", \"verify PR #N\", \"qa test pr\", \"qa this branch\", \"test this branch\", or any intent to manually test/verify a GitHub PR or branch on the iOS simulator. Builds the PR branch, analyzes what changed, derives test scenarios from the PR description and diff, spins up simulator(s), navigates the app, takes screenshots, and posts a QA comment on the PR. DO NOT TRIGGER for: code reviews, static analysis, linting, writing tests, or debugging a build error."
---

# qa-branch

End-to-end QA testing of a GitHub PR on iOS simulator(s). Analyzes the PR to derive test scenarios, builds the branch, navigates the app, captures evidence screenshots, and posts a structured QA comment back to the PR.

---

## Phase 0 — Gather Inputs

**Required:** Extract the PR number from the user's message. If not provided, ask for it.

**Ask the user one question before proceeding:**

> "Do you need iPad testing in addition to iPhone? (y/n)"

Wait for the answer. Store as `IPAD_NEEDED` (`true`/`false`). Then proceed autonomously — do not ask further questions.

---

## Phase 1 — PR & Code Analysis (parallel)

Run all of the following in parallel to maximize speed:

### 1a. Discover repo and fetch PR metadata
```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
gh pr view <PR_NUMBER> --repo "$REPO" \
  --json title,body,headRefName,baseRefName,state
```

Extract:
- `BRANCH_NAME` — the head branch
- `BASE_BRANCH` — the base branch (used for cleanup in Phase 7)
- `PR_TITLE` — for the comment header
- `PR_BODY` — scan for acceptance criteria items and "How to Test" steps

### 1b. Fetch PR diff and changed files
```bash
gh pr diff <PR_NUMBER> --repo "$REPO" | head -2000
gh pr view <PR_NUMBER> --repo "$REPO" --json files \
  --jq '.files[].path'
```

### 1c. Discover available simulators
```bash
xcrun simctl list devices available | grep -E "iPhone [0-9]+ \(" | head -5
xcrun simctl list devices available | grep -E "iPad" | head -5
```

Store:
- `IPHONE_UDID` — first available booted or available iPhone from the list
- `IPAD_UDID` — first available iPad from the list (only needed if `IPAD_NEEDED=true`)

### 1d. Discover project build settings
```bash
XCODEPROJ=$(find . -maxdepth 2 -name "*.xcodeproj" | head -1)
SCHEME=$(basename "$XCODEPROJ" .xcodeproj)
APP_NAME="$SCHEME"
```

### 1e. Scenario derivation (do this yourself — no agent needed)

From the PR description and diff, identify:

1. **Changed UI surfaces** — which screens/tabs are affected? Read the changed file paths from the diff and map them to feature names (e.g. files under `*/Screens/Login/` → Login screen, `*/Components/` → shared components that affect many screens).

2. **Changed libraries** — infer test focus from dependency upgrades:
   - **Nuke / SDWebImage / Kingfisher** → image loading on all image-heavy screens (feeds, lists, detail views, thumbnails)
   - **Parchment / TabMan** → paged/tabbed views and segment controls
   - **Lottie** → animated views, tab bar icons, loading indicators
   - **Apollo / GraphQL** → any screen that fetches data from the API

3. **Acceptance criteria** — each numbered criterion from the PR description becomes a test scenario

4. **How to Test steps** — use these as navigation instructions where possible

Build `TEST_SCENARIOS`: an ordered list, e.g.:
```
1. [Image loading] Verify images load correctly on the main feed and detail screens
2. [Paged views] Tap each segment in the tabbed view and verify content loads
3. [Lottie] Switch across all tab bar tabs and verify icons render
4. [AC1] <exact acceptance criterion text>
```

**Parallel simulator assessment:** Since each simulator is fully independent and WDA handles tap routing by UDID, ALL scenarios can run on separate simulators simultaneously if hardware allows. Decide the split:
- **iPhone only (`IPAD_NEEDED=false`):** run all scenarios sequentially on one iPhone
- **iPhone + iPad (`IPAD_NEEDED=true`):** run the same key scenarios on both devices; iPhone gets all scenarios, iPad gets the subset most likely to differ at a wider layout (paged views, image grids, modals)

Print a plan summary before proceeding:
```
╔══════════════════════════════════════════════════════╗
║  qa-branch — PR #<N>: <title>                        ║
║  Branch: <branch>                                    ║
║  Scenarios: <X>  |  Simulators: <iphone> [+ ipad]   ║
╚══════════════════════════════════════════════════════╝
```

---

## Phase 2 — Checkout & Build

### 2a. Checkout the PR branch
```bash
git fetch origin <BRANCH_NAME> && git checkout <BRANCH_NAME>
```

If already on the branch, just pull:
```bash
git pull origin <BRANCH_NAME>
```

### 2b. Load SSH keys (required for private SPM dependencies)
```bash
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

### 2c. Resolve packages
```bash
xcodebuild -resolvePackageDependencies \
  -project "$XCODEPROJ" \
  -scheme "$SCHEME" 2>&1 | tail -5
```

If resolve fails with "already exists in file system":
```bash
DERIVED_DATA=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "${SCHEME}-*" -type d | head -1)
rm -rf ~/Library/Caches/org.swift.swiftpm/
rm -rf "$DERIVED_DATA/SourcePackages/"
xcodebuild -resolvePackageDependencies -project "$XCODEPROJ" -scheme "$SCHEME" 2>&1 | tail -5
```

### 2d. Build
```bash
xcodebuild build \
  -project "$XCODEPROJ" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=<IPHONE_UDID>" \
  2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | tail -20
```

**If build fails:**
- Check error output for missing symbols or framework errors
- If module cache issue: run `DERIVED_DATA=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "${SCHEME}-*" -type d | head -1) && rm -rf "$DERIVED_DATA/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/" ~/Library/Developer/Xcode/ModuleCache.noindex/` then retry build once
- Stop and report to the user if build still fails after retry; do NOT proceed to testing

Report build status:
- ✅ `BUILD SUCCEEDED` — continue
- ❌ `BUILD FAILED` — stop, show errors, return to user

---

## Phase 3 — Simulator Setup

Run all setup steps in parallel where possible.

### 3a. Boot simulators
```bash
# Boot iPhone (always)
xcrun simctl boot <IPHONE_UDID> 2>/dev/null || true
open -a Simulator

# Boot iPad (if IPAD_NEEDED)
xcrun simctl boot <IPAD_UDID> 2>/dev/null || true
```

Wait 3 seconds after booting.

### 3b. Install app on all simulators
```bash
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 4 -name "${APP_NAME}.app" -path "*/Debug-iphonesimulator/*" | head -1)
BUNDLE_ID=$(defaults read "$APP_PATH/Info.plist" CFBundleIdentifier)

# iPhone
xcrun simctl install <IPHONE_UDID> "$APP_PATH"
xcrun simctl launch <IPHONE_UDID> "$BUNDLE_ID"

# iPad (if IPAD_NEEDED) — same app binary works for both
xcrun simctl install <IPAD_UDID> "$APP_PATH"
xcrun simctl launch <IPAD_UDID> "$BUNDLE_ID"
```

### 3c. Start WDA on each simulator
WDA must be started before any tap/swipe commands. Each simulator needs its own port.

```bash
# iPhone — port 8100
sim --device <IPHONE_UDID> wda-start 8100

# iPad — port 8101 (if IPAD_NEEDED)
sim --device <IPAD_UDID> wda-start 8101
```

Wait for each to print `WDA ready: port=...` before continuing.

**Alternative — one-shot setup** (boots sim + builds WDA if needed + installs app + starts WDA):
```bash
sim --device <IPHONE_UDID> setup "$APP_PATH" --port 8100
```

**Known issue — WDA broken on iPhone 16 iOS 18.1:** The Appium WDA xctest bundle targets `MinimumOSVersion = "26.2"` and will fail to start on iOS 18.1. If `wda-start` fails, see the error handling table below. WDA taps are UDID-scoped so separate simulators do NOT need a global serialization queue — parallel taps to different simulators are safe.

---

## Phase 4 — Test Execution & Screenshots

### Setup
```bash
SCREENSHOTS_DIR="/tmp/pr<PR_NUMBER>-qa-$(date +%Y%m%d%H%M%S)"
mkdir -p "$SCREENSHOTS_DIR"
SIM="sim"
IPHONE="<IPHONE_UDID>"
IPAD="<IPAD_UDID>"   # only if IPAD_NEEDED
```

### Navigation commands reference

**CRITICAL — each separate Bash tool call costs ~10s of API latency.** Always batch sequential sim calls with `&&` in ONE Bash tool call. 20 calls batched into 5 cuts total time from ~240s to ~60s.

```bash
# ★ Read current screen — do this first on any new screen
$SIM --device $IPHONE layout-map

# ★ Best navigation primitive — find + tap + wait + return new layout-map in ONE call
$SIM --device $IPHONE tap-and-wait "<label>" "<expected_screen_text>" 8

# Navigate to a tab — get x,y from layout-map navigation.tabs[].x/y (NEVER hardcode)
# Batch the tab tap + wait together:
$SIM --device $IPHONE tap <TAB_X> <TAB_Y> && $SIM --device $IPHONE wait-for "<TabName>" 5

# Tap a segment/button and read the result in one call:
$SIM --device $IPHONE tap-element "<segment_label>" && $SIM --device $IPHONE layout-map

# Scroll and check what changed:
$SIM --device $IPHONE scroll-down && $SIM --device $IPHONE layout-map

# Scroll until an element is visible, then tap:
$SIM --device $IPHONE scroll-to-visible "<label>" 10 && \
  $SIM --device $IPHONE tap-element "<label>"

# Close a modal (tap the close/X button):
$SIM --device $IPHONE tap <X_BTN_X> <X_BTN_Y> && $SIM --device $IPHONE wait-for "<next_element>" 5
```

**Tab bar coordinates:** Always read from `layout-map` → `navigation.tabs[].x` and `navigation.tabs[].y`. Never use hardcoded values — they vary by device and session.

**Screenshot naming convention:**
- `<NN>_<device>_<scenario>.png`
- Examples: `01_iphone_home_feed.png`, `02_ipad_detail_view.png`

### Execute test scenarios

For each scenario in `TEST_SCENARIOS`:
1. Use `layout-map` to understand the current screen before acting
2. Navigate using `tap-and-wait` (preferred) — it taps, waits, and returns a fresh layout-map in one call
3. Scroll to reveal content with `scroll-to-visible "<label>"` then `tap-element "<label>"`
4. Take a `screenshot` only as final evidence for the PR comment — not for navigation decisions
5. Note pass/fail for the scenario

**Key test patterns by library:**

**Image loading (Nuke / SDWebImage / Kingfisher):**
- Navigate to any feed or list screen → `scroll-down` → `screenshot`
- Open a detail view that has a hero image → `screenshot`
- Check: no broken/gray placeholder images visible

**Paged views (Parchment / TabMan):**
- Navigate to any screen with a segment control or paged tabs
- Tap each segment via `tap-element` → `layout-map` to verify content loaded → `screenshot`
- Check: correct content loads per segment, selection indicator moves, scroll works

**Animations (Lottie):**
- Tap each tab bar tab via `tap-and-wait` → `screenshot` after each
- Navigate to any screen with a Lottie loading indicator if present
- Check: animated elements render (not blank/invisible), no crash on interaction

**General (every scenario):**
- App must not crash
- Navigation must complete (no frozen screens) — `layout-map` is the fastest way to verify
- Content must be visible (no blank screens)

---

## Phase 5 — Screenshots

Screenshots are saved to `$SCREENSHOTS_DIR`. Reference them in the PR comment by uploading via your project's preferred method (e.g. drag-drop into the GitHub PR, a project upload script, or `gh` API). Store the resulting markdown image references as `IMAGE_MARKDOWN`.

---

## Phase 6 — PR Comment

Post a structured QA comment to the PR:

```bash
gh pr comment <PR_NUMBER> --repo "$REPO" --body "$(cat <<'COMMENT'
## QA Testing — <PR_TITLE>

Tested on **<device list>** · Branch: `<BRANCH_NAME>`

---

### Build
✅ Clean build — no errors

---

### Test Results

| # | Scenario | Result | Notes |
|---|---|---|---|
| 1 | <scenario description> | ✅ Pass / ❌ Fail | <one-line note> |
| 2 | ... | ... | ... |

---

### Screenshots

<group screenshots by scenario using markdown tables, 2-3 per row>

| <label> | <label> | <label> |
|---|---|---|
| ![...](url) | ![...](url) | ![...](url) |

---

<overall verdict: one sentence>
COMMENT
)"
```

**Comment rules:**
- Group screenshots by scenario (not by device) — if iPad tested, add an "iPad" column or a separate section
- Use the exact acceptance criteria labels from the PR description in the results table
- If a scenario can't be tested (e.g., requires login state you don't have), mark as `⚠ Skipped` with reason
- If anything fails: describe what was observed and include the failure screenshot

---

## Phase 7 — Cleanup & Return to base branch

```bash
git checkout "$BASE_BRANCH"
```

Send a macOS notification:
```bash
osascript -e 'display notification "QA complete — comment posted to PR #<N>" with title "qa-branch ✅" sound name "Glass"'
```

---

## Key Constants (discovered at runtime)

- **Repo:** `REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')`
- **Project:** `XCODEPROJ=$(find . -maxdepth 2 -name "*.xcodeproj" | head -1)`
- **Scheme:** `SCHEME=$(basename "$XCODEPROJ" .xcodeproj)`
- **App path:** `find ~/Library/Developer/Xcode/DerivedData -maxdepth 4 -name "${APP_NAME}.app" -path "*/Debug-iphonesimulator/*" | head -1`
- **Bundle ID:** `defaults read "$APP_PATH/Info.plist" CFBundleIdentifier`
- **DerivedData:** `find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "${SCHEME}-*" -type d | head -1`
- **WDA port convention:** iPhone=8100, iPad=8101, second iPhone=8102

## Error Handling

| Failure | Action |
|---|---|
| Build fails after retry | Stop, report errors, do NOT test |
| WDA fails to start | Retry once; if still fails, try killing stale WDA processes: `pkill -f WebDriverAgentRunner` then retry |
| Screenshot directory not writable | Use `mktemp -d` as fallback |
| App crashes during test | Screenshot the crash state, mark scenario as ❌ Fail, continue remaining scenarios |
| `tap-and-wait` times out | Fall back to `tap <x> <y> && wait-for "<expected_label>" 10` using coordinates from `layout-map` |
| iPad simulator unavailable | Set `IPAD_NEEDED=false`, note in comment that iPad test was skipped (no hardware) |
