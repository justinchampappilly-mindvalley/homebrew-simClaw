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

### 1a. Fetch PR metadata
```bash
gh pr view <PR_NUMBER> --repo mindvalley/Mobile_iOS_Mindvalley \
  --json title,body,headRefName,baseRefName,state
```

Extract:
- `BRANCH_NAME` — the head branch
- `PR_TITLE` — for the comment header
- `PR_BODY` — scan for Expected Behaviour items (EB1, EB2, ...) and "How to Test" steps

### 1b. Fetch PR diff and changed files
```bash
gh pr diff <PR_NUMBER> --repo mindvalley/Mobile_iOS_Mindvalley | head -2000
gh pr view <PR_NUMBER> --repo mindvalley/Mobile_iOS_Mindvalley --json files \
  --jq '.files[].path'
```

### 1c. Discover available simulators
```bash
xcrun simctl list devices available | grep -E "iPhone 16 \(" | head -5
xcrun simctl list devices available | grep -E "iPad" | head -5
```

Store:
- `IPHONE_UDID` — prefer `A0F9CB4E-ECF0-461B-A80E-C20810D732EA` (primary iPhone 16). Confirm it appears in the list; if not, pick the first available iPhone 16.
- `IPAD_UDID` — first available iPad from the list (only needed if `IPAD_NEEDED=true`)

### 1d. Scenario derivation (do this yourself — no agent needed)

From the PR description and diff, identify:

1. **Changed UI surfaces** — which screens/tabs are affected? Look for file paths under:
   - `Mindvalley/Modules/` → legacy UIKit module name
   - `Mindvalley/NextGen/Screens/` → SwiftUI screen name
   - `Mindvalley/NextGen/EveAI/` → Eve AI chat
   - `Mindvalley/NextGen/Components/` → shared components (many screens)

2. **Changed libraries** — infer test focus from dependency upgrades:
   - **Nuke** → image loading on all image-heavy screens (feeds, quest covers, profiles, thumbnails)
   - **Parchment** → paged/tabbed views (Programs tab segments, Meditations segments)
   - **Lottie** → animated views, especially tab bar icons and loading indicators
   - **SDWebImage / Kingfisher** → same as Nuke
   - **Apollo** → GraphQL-driven screens (any feed or data-fetching view)

3. **Expected Behaviour items** — each `EB{N}` item from the PR description becomes a test scenario

4. **How to Test steps** — use these as navigation instructions where possible

Build `TEST_SCENARIOS`: an ordered list, e.g.:
```
1. [Nuke] Image loading — Today feed, Programs list, quest cover art
2. [Parchment] Paged view tabs — Programs: Discover → Masteries → Courses
3. [Lottie] Tab bar animations — switch across all 5 tabs
4. [EB3] Acceptance: <exact EB text>
```

**Parallel simulator assessment:** Since each simulator is fully independent and WDA handles tap routing by UDID, ALL scenarios can run on separate simulators simultaneously if hardware allows. Decide the split:
- **iPhone only (`IPAD_NEEDED=false`):** run all scenarios sequentially on one iPhone
- **iPhone + iPad (`IPAD_NEEDED=true`):** run the same key scenarios on both devices; iPhone gets all scenarios, iPad gets the subset most likely to differ at a wider layout (paged views, image grids, modals)

Print a plan summary before proceeding:
```
╔══════════════════════════════════════════════════════╗
║  pr-qa-test — PR #<N>: <title>                       ║
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
  -project Mindvalley.xcodeproj \
  -scheme "Mindvalley" 2>&1 | tail -5
```

If resolve fails with "already exists in file system":
```bash
DERIVED_DATA=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "Mindvalley-*" -type d | head -1)
rm -rf ~/Library/Caches/org.swift.swiftpm/
rm -rf "$DERIVED_DATA/SourcePackages/"
xcodebuild -resolvePackageDependencies -project Mindvalley.xcodeproj -scheme "Mindvalley" 2>&1 | tail -5
```

### 2d. Build
```bash
xcodebuild build \
  -project Mindvalley.xcodeproj \
  -scheme "Mindvalley" \
  -destination "platform=iOS Simulator,id=<IPHONE_UDID>" \
  2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | tail -20
```

**If build fails:**
- Check error output for missing symbols or framework errors
- If module cache issue: run `DERIVED_DATA=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "Mindvalley-*" -type d | head -1) && rm -rf "$DERIVED_DATA/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/" ~/Library/Developer/Xcode/ModuleCache.noindex/` then retry build once
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
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 4 -name "Mindvalley.app" -path "*/Debug-iphonesimulator/*" | head -1)

# iPhone
xcrun simctl install <IPHONE_UDID> "$APP_PATH"
xcrun simctl launch <IPHONE_UDID> com.mindvalley.mvacademy

# iPad (if IPAD_NEEDED) — note: same app binary works for both
xcrun simctl install <IPAD_UDID> "$APP_PATH"
xcrun simctl launch <IPAD_UDID> com.mindvalley.mvacademy
```

### 3c. Start WDA on each simulator
WDA must be started before any tap/swipe commands. Each simulator needs its own port.

```bash
# iPhone — port 8100
sim \
  --device <IPHONE_UDID> wda-start 8100

# iPad — port 8101 (if IPAD_NEEDED)
sim \
  --device <IPAD_UDID> wda-start 8101
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

**CRITICAL — each separate Bash tool call costs ~10s of API latency.** Always batch sequential sim.sh calls with `&&` in ONE Bash tool call. 20 calls batched into 5 cuts total time from ~240s to ~60s.

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

# Scroll until an element is visible, then use layout-map to get its coordinates, then tap:
$SIM --device $IPHONE scroll-to-visible "<label>" 10 && \
  $SIM --device $IPHONE tap-element "<label>"

# Close a modal (tap the close/X button):
$SIM --device $IPHONE tap <X_BTN_X> <X_BTN_Y> && $SIM --device $IPHONE wait-for "<next_element>" 5
```

**Tab bar coordinates:** Always read from `layout-map` → `navigation.tabs[].x` and `navigation.tabs[].y`. Never use hardcoded values — they vary by device and session.

**Screenshot naming convention:**
- `<NN>_<device>_<scenario>.png`
- Examples: `01_iphone_today_feed.png`, `02_ipad_programs_discover.png`

### Execute test scenarios

For each scenario in `TEST_SCENARIOS`:
1. Use `layout-map` to understand the current screen before acting
2. Navigate using `tap-and-wait` (preferred) — it taps, waits, and returns a fresh layout-map in one call
3. Scroll to reveal content with `scroll-to-visible "<label>"` then `tap-element "<label>"`
4. Take a `screenshot` only as final evidence for the PR comment — not for navigation decisions
5. Note pass/fail for the scenario

**Key test patterns by library:**

**Nuke (image loading):**
- Navigate to Today tab via `tap-and-wait` → `scroll-down` → `screenshot` (quest cover art, author thumbnails)
- Navigate to Programs → `layout-map` to verify content loaded → `screenshot` program list (cover images)
- Open a program detail → `screenshot` (hero cover image)
- Check: no broken/gray placeholder images visible

**Parchment (paged views):**
- Navigate to Programs tab → tap each segment via `tap-element` → `layout-map` to verify content → `screenshot` each
- Navigate to Meditations → tap each segment → `layout-map` to verify → `screenshot`
- Check: correct content loads per segment, selection indicator moves, scroll works

**Lottie (animations):**
- Tap each tab bar tab via `tap-and-wait` → `screenshot` after each (animations are frame-captured, not video)
- Navigate to any screen with a Lottie loading indicator if present
- Check: tab bar icons render (not blank/invisible), no crash on tab switch

**Eve AI:**
- Tap Eve AI tab → `layout-map` to confirm chat UI loaded → `screenshot`
- Check: chat UI loads, no crash

**General (every scenario):**
- App must not crash
- Navigation must complete (no frozen screens) — `layout-map` is the fastest way to verify
- Content must be visible (no blank screens)

---

## Phase 5 — Screenshot Resize & Upload

### Resize and upload in one step
Use the `--resize 390` flag in the upload script — it handles resizing internally before uploading. No separate `sips` step needed.

```bash
python3 Scripts/github_upload_image.py \
  --resize 390 \
  $SCREENSHOTS_DIR/*.png
```

Collect all returned `![name](url)` markdown lines. Store as `IMAGE_MARKDOWN`.

---

## Phase 6 — PR Comment

Post a structured QA comment to the PR:

```bash
gh pr comment <PR_NUMBER> --repo mindvalley/Mobile_iOS_Mindvalley --body "$(cat <<'COMMENT'
## QA Testing — <PR_TITLE>

Tested on **<device list>** · Branch: `<BRANCH_NAME>`

---

### Build
✅ Clean build — no errors

---

### Test Results

| # | Scenario | Result | Notes |
|---|---|---|---|
| EB1 | <scenario description> | ✅ Pass / ❌ Fail | <one-line note> |
| EB2 | ... | ... | ... |

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
- Use the exact `EB{N}` labels from the PR description in the results table
- If a scenario can't be tested (e.g., requires login state you don't have), mark as `⚠ Skipped` with reason
- If anything fails: describe what was observed and include the failure screenshot

---

## Phase 7 — Cleanup & Return to development

```bash
git checkout development
```

Send a macOS notification:
```bash
osascript -e 'display notification "QA complete — comment posted to PR #<N>" with title "qa-branch ✅" sound name "Glass"'
```

---

## Key Constants

- **App bundle ID:** `com.mindvalley.mvacademy`
- **Primary iPhone 16 UDID:** `A0F9CB4E-ECF0-461B-A80E-C20810D732EA`
- **Build flag:** use `-project Mindvalley.xcodeproj` NOT `-workspace`
- **DerivedData:** `$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "Mindvalley-*" -type d | head -1)` (hash suffix is machine-specific)
- **sim:** `sim` (installed via `brew install simclaw`)
- **Upload script:** `python3 Scripts/github_upload_image.py --resize 390`
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
