---
name: qa-branch
description: "TRIGGER on: \"test this PR\", \"QA this PR\", \"run QA on PR\", \"test the changes in PR\", \"verify PR #N\", \"qa test pr\", \"qa this branch\", \"test this branch\", or any intent to manually test/verify a GitHub PR or branch on the iOS simulator. Builds the PR branch, analyzes what changed, derives test scenarios, spins up one simulator per scenario, spawns one agent per scenario (all in parallel), and posts a unified QA comment on the PR. DO NOT TRIGGER for: code reviews, static analysis, linting, writing tests, or debugging a build error."
---

# qa-branch

End-to-end QA testing of a GitHub PR. The parent sets up one simulator per scenario, then spawns one background agent per scenario — all in a single message for true parallelism. Results are aggregated into one PR comment.

**Architecture:**
- 3 iPhone scenarios → 3 iPhone simulators → 3 iPhone agents running simultaneously
- 3 iPad scenarios → 3 iPad simulators → 3 iPad agents running simultaneously
- Total: 6 agents running in parallel, each focused on exactly one scenario

---

## Phase 0 — Prerequisites & Gather Inputs

### 0a. Verify `sim` tool is installed

```bash
SIM=$(which sim)
echo "SIM=$SIM"
```

If `which sim` fails (exit code 1 / empty output), **stop and tell the user:**

> "`sim` (simClaw) is required for QA testing but is not installed. Install it with:
> ```
> brew install simclaw
> ```
> Then re-run this skill."

Do NOT proceed without `sim`. All simulator interaction (tap, navigate, screenshot, layout-map) depends on it.

### 0b. Gather inputs

**Required:** Extract the PR number from the user's message. If not provided, and we are on a feature branch, use the current branch. If neither is available, ask for it.

**Ask the user one question before proceeding:**

> "Do you need iPad testing in addition to iPhone? (y/n)"

Wait for the answer. Store as `IPAD_NEEDED` (`true`/`false`). Then proceed autonomously.

---

## Phase 1 — PR & Code Analysis (all parallel)

### 1a. Fetch PR metadata
```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
gh pr view <PR_NUMBER> --repo "$REPO" \
  --json title,body,headRefName,baseRefName,state
```

Extract: `BRANCH_NAME`, `BASE_BRANCH`, `PR_TITLE`, `PR_BODY`

### 1b. Fetch PR diff and changed files
```bash
gh pr diff <PR_NUMBER> --repo "$REPO" | head -2000
gh pr view <PR_NUMBER> --repo "$REPO" --json files --jq '.files[].path'
```

### 1c. Discover available simulators
```bash
# List all available iPhones and iPads, grouping by iOS version
xcrun simctl list devices available | grep -E "iPhone [0-9]+" | head -10
xcrun simctl list devices available | grep -E "iPad" | head -10

# Also identify which iOS runtimes are available
xcrun simctl list runtimes available | grep -i ios
```

Collect UDIDs into two lists:
- `IPHONE_UDIDS[]` — one per iPhone scenario needed (use different iPhone models if available; reuse same model with different UDIDs if not)
- `IPAD_UDIDS[]` — one per iPad scenario needed (only if `IPAD_NEEDED=true`)

**Multi-OS testing:** If the user requests testing on multiple iOS versions (e.g., iOS 18 AND iOS 26), allocate one simulator per iOS version per scenario. Each iOS version × scenario combination gets its own agent.

Port allocation:
- iPhones: `8100`, `8101`, `8102`, ... (one per iPhone scenario)
- iPads: `8200`, `8201`, `8202`, ... (one per iPad scenario)

### 1d. Discover project build settings
```bash
XCODEPROJ=$(find . -maxdepth 2 -name "*.xcodeproj" | head -1)
SCHEME=$(basename "$XCODEPROJ" .xcodeproj)
APP_NAME="$SCHEME"

# Detect project type — workspace vs project
if [[ -f "$(find . -maxdepth 2 -name '*.xcworkspace' | head -1)" ]]; then
  BUILD_FLAG="-workspace $(find . -maxdepth 2 -name '*.xcworkspace' | head -1)"
else
  BUILD_FLAG="-project $XCODEPROJ"
fi
```

### 1e. Scenario derivation

From the PR description and diff, derive:
1. **Changed UI surfaces** — map file paths to feature names
2. **Changed libraries** — map changed dependencies to affected UI surfaces
3. **Acceptance criteria** — each criterion becomes one scenario
4. **How to Test steps** — use as navigation instructions

Build two numbered lists. Each item is ONE discrete scenario — atomic, independently testable:
- `IPHONE_SCENARIOS[1..N]` — full coverage
- `IPAD_SCENARIOS[1..M]` — layout-sensitive subset (wider layout differences only)

Print a plan summary:
```
╔══════════════════════════════════════════════════════════════════╗
║  qa-branch — PR #<N>: <title>                                    ║
║  Branch: <branch>                                                ║
║  iPhone: <N> scenarios × <N> simulators × <N> agents            ║
║  iPad:   <M> scenarios × <M> simulators × <M> agents            ║
║  Total agents: <N+M> running in parallel                         ║
╚══════════════════════════════════════════════════════════════════╝
```

---

## Phase 2 — Checkout & Build

### 2a. Checkout the PR branch
```bash
git fetch origin <BRANCH_NAME> && git checkout <BRANCH_NAME>
```
If already on branch: `git pull origin <BRANCH_NAME>`

### 2b. Load SSH keys
```bash
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

### 2c. Resolve packages (if needed)
```bash
xcodebuild -resolvePackageDependencies $BUILD_FLAG -scheme "$SCHEME" 2>&1 | tail -5
```
If resolve fails with "already exists in file system":
```bash
DERIVED_DATA=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "${SCHEME}-*" -type d | head -1)
rm -rf ~/Library/Caches/org.swift.swiftpm/ "$DERIVED_DATA/SourcePackages/"
xcodebuild -resolvePackageDependencies $BUILD_FLAG -scheme "$SCHEME" 2>&1 | tail -5
```

### 2d. Build (against the first available iPhone UDID)
```bash
xcodebuild build \
  $BUILD_FLAG -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=<IPHONE_UDIDS[0]>" \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -10
```
If build fails → stop, report to user, do NOT proceed.

---

## Phase 3 — Simulator Setup (one per scenario)

### 3a. Clear all stale sim state
```bash
sim cleanup
```

### 3b. Locate app binary
```bash
# $SIM was resolved in Phase 0a
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 5 \
  -name "${APP_NAME}.app" -path "*/Debug-iphonesimulator/*" | head -1)
echo "App: $APP_PATH"
```

### 3c. Setup all simulators (sequential to avoid WDA port collisions)

Run `sim setup` for each simulator. The sim tool now handles WDA failure gracefully — if WDA can't start (e.g., iOS 18 with SDK mismatch), setup still completes (boot + install + launch) and reports `WDA: unavailable` instead of failing. Parse the output to determine WDA status per simulator.

```bash
# Run setup for each simulator — capture output to determine WDA status
for i in "${!ALL_UDIDS[@]}"; do
  UDID="${ALL_UDIDS[$i]}"
  PORT="${ALL_PORTS[$i]}"
  OUTPUT=$($SIM --device "$UDID" setup "$APP_PATH" --port "$PORT" 2>&1)
  echo "$OUTPUT"
  if echo "$OUTPUT" | grep -q "WDA:.*ready"; then
    WDA_STATUS[$i]="true"
  else
    WDA_STATUS[$i]="false"
  fi
done
```

**No separate health-check phase needed** — `sim setup` now reports WDA status directly. Pass `WDA_AVAILABLE=true|false` to each scenario agent based on the setup output.

**WDA failure is NOT a reason to skip a simulator.** The scenario agent receives `WDA_AVAILABLE=false` and uses screenshot-based verification with AX fallback commands instead.

---

## Phase 4 — Spawn one agent per scenario (all in parallel)

### CRITICAL: spawn all agents in a single message

Use the `Agent` tool with `run_in_background=true`. To run all agents truly in parallel, ALL Agent tool calls must appear in ONE response message. Issuing them across multiple messages makes them sequential.

```
# CORRECT — N+M agents all in one message:
Agent(prompt="<iphone scenario 1 prompt>", run_in_background=true)
Agent(prompt="<iphone scenario 2 prompt>", run_in_background=true)
Agent(prompt="<iphone scenario 3 prompt>", run_in_background=true)
Agent(prompt="<ipad scenario 1 prompt>",   run_in_background=true)
Agent(prompt="<ipad scenario 2 prompt>",   run_in_background=true)

# WRONG — sequential:
Agent(...)  # wait, then...
Agent(...)  # wait, then...
```

### Scenario agent prompt template

Each agent gets exactly ONE scenario. Fill all placeholders.

```
You are running one iOS QA scenario for PR #<N> ("<PR_TITLE>").

## Your single scenario
<SCENARIO_NUMBER>. <SCENARIO_DESCRIPTION>
Navigation steps: <HOW_TO_TEST steps relevant to this scenario>

## Device
Label: <DEVICE_LABEL>  (e.g. "iPhone 16 #1", "iPad Pro 11-inch #2")
UDID: <UDID>
WDA port: <PORT>
Screenshots dir: /tmp/pr<N>-qa-<TIMESTAMP>/<SCENARIO_SLUG>/
(create it: mkdir -p /tmp/pr<N>-qa-<TIMESTAMP>/<SCENARIO_SLUG>/)

## Project constants
SIM="<SIM_PATH>"   # resolved path to sim tool (from Phase 0a)
BUNDLE_ID="<BUNDLE_ID>"
REPO="<REPO>"
Branch: <BRANCH_NAME>
WDA_AVAILABLE=<true|false>  # whether WDA is running on this simulator
App already installed on this simulator — do NOT run setup.

## Navigation

### If WDA_AVAILABLE=true
Use sim commands for all interactions. sim tap uses WDA pointer actions internally.

Primary workflow:
1. $SIM --device <UDID> layout-map     — see what's on screen
2. $SIM --device <UDID> tap-and-wait "<label>" — tap + wait + get new layout-map
3. $SIM --device <UDID> screenshot <path>      — capture evidence

If tap-and-wait fails, try direct coordinates:
1. $SIM --device <UDID> find-element "<label>"  — get element coordinates
2. $SIM --device <UDID> tap <x> <y>             — tap at coordinates
3. $SIM --device <UDID> wait-for "<label>"      — wait for expected element

Other useful commands:
- $SIM --device <UDID> tap-element "<label>"    — tap by accessibility label
- $SIM --device <UDID> scroll-to-visible "<label>" — scroll until element visible
- $SIM --device <UDID> scroll-down / scroll-up  — manual scroll
- $SIM --device <UDID> type "<text>"            — type into focused field
- $SIM --device <UDID> wait-for-stable          — wait for screen to stabilize
- $SIM --device <UDID> describe                 — describe visible screen
- $SIM --device <UDID> screen-title             — get current screen title

### If WDA_AVAILABLE=false (degraded mode — e.g. older iOS where WDA SDK is incompatible)
WDA is NOT running. You can still take screenshots and do limited verification:
1. `xcrun simctl io <UDID> screenshot <path>` — take screenshots
2. `$SIM --device <UDID> wait-for "<label>"` — AX-based element detection (works without WDA)
3. `$SIM --device <UDID> describe` — AX-based screen description (works without WDA)
4. `$SIM --device <UDID> describe-point <x> <y>` — hit-test AX element at coordinate

For navigation without WDA, use CGEvent tapping via a compiled Swift helper:
1. First, compile the tap helper (if not already at /tmp/simtap):
   ```bash
   if [[ ! -x /tmp/simtap ]]; then
     cat > /tmp/simtap.swift << 'SWIFT'
   import Cocoa
   let x = CGFloat(Double(CommandLine.arguments[1])!)
   let y = CGFloat(Double(CommandLine.arguments[2])!)
   let p = CGPoint(x: x, y: y)
   CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
   CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
   Thread.sleep(forTimeInterval: 0.05)
   CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
   SWIFT
     xcrun swiftc -o /tmp/simtap /tmp/simtap.swift
   fi
   ```
2. Use AX probing to find macOS screen coordinates of interactive elements:
   ```bash
   # Compile an AX probe to find element positions (outputs JSON with macOS coords)
   # Use describe-point to hit-test at specific coordinates
   $SIM --device <UDID> describe-point <estimated_x> <estimated_y>
   ```
3. Activate the correct simulator window, then tap:
   ```bash
   osascript -e 'tell application "System Events" to tell process "Simulator" to perform action "AXRaise" of (first window whose name contains "<DEVICE_NAME>")'
   sleep 0.3
   /tmp/simtap <macOS_x> <macOS_y>
   ```

In degraded mode, focus on screenshot-based visual verification. If navigation is too difficult, take a screenshot of the landing screen and report what you can observe.

## Login / Authentication screens
If you encounter a login page, sign-in screen, or any authentication prompt at ANY point
during navigation, you MUST stop and output this JSON immediately:
{
  "scenario": "<SCENARIO_DESCRIPTION>",
  "device": "<DEVICE_LABEL>",
  "udid": "<UDID>",
  "result": "blocked",
  "note": "Login screen encountered — credentials required",
  "screenshot": "/tmp/pr<N>-qa-<TIMESTAMP>/<SCENARIO_SLUG>/login_blocked.png"
}
Take a screenshot of the login screen BEFORE outputting the JSON.
Do NOT attempt to guess credentials or skip the login. Do NOT mark as skipped or failed.
The parent agent will collect your result, ask the user for credentials, and re-run you.

## CRITICAL RULES

### Do NOT troubleshoot WDA
If WDA_AVAILABLE=false, accept it. Do NOT attempt to:
- Start WDA yourself (curl, xcodebuild, wda-start)
- Patch WDA binaries or xctestrun files
- Create WDA sessions manually
- Fix bootstrap cache files
WDA setup was already handled by the parent orchestrator. If it failed, it's because the
iOS version is incompatible. Use the degraded-mode fallback commands listed above.

### Performance — batch commands
Each Bash tool call costs ~10s API latency. Always batch with &&.
- BAD:  sim tap-element "Login" / then / sim wait-for "Home" / then / sim screenshot path.png
- GOOD: sim tap-element "Login" && sim wait-for "Home" 10 && sim screenshot path.png  (one call)

Use sim tap-and-wait when possible — it does tap + wait + layout-map in ONE call.
layout-map has a built-in fallback for AX tree timeouts — no manual recovery needed.

### Stay focused
You have ONE job: verify your scenario and report pass/fail with a screenshot.
Do not explore unrelated screens, fix infrastructure, or exceed 15 Bash tool calls total.

## Steps
1. mkdir -p /tmp/pr<N>-qa-<TIMESTAMP>/<SCENARIO_SLUG>/
2. sim --device <UDID> health-check  — verify WDA is alive
3. sim --device <UDID> layout-map    — orient yourself
4. Navigate to the feature under test using sim commands (tap-and-wait, tap-element, etc.)
5. Verify the scenario passes or fails
6. sim --device <UDID> screenshot /tmp/pr<N>-qa-<TIMESTAMP>/<SCENARIO_SLUG>/evidence.png
7. Output the JSON result below

## Output format
IMPORTANT: Do NOT post a PR comment. Do NOT call gh pr comment.
Output ONLY this JSON:
{
  "scenario": "<SCENARIO_DESCRIPTION>",
  "device": "<DEVICE_LABEL>",
  "udid": "<UDID>",
  "result": "pass|fail|skipped|blocked",
  "note": "<one-line observation>",
  "screenshot": "/tmp/pr<N>-qa-<TIMESTAMP>/<SCENARIO_SLUG>/evidence.png"
}
```

### Wait for all agents

Wait for task-completion notifications from every spawned agent. Collect all JSON result objects. Do not post the PR comment until every agent has responded.

### Handle login-blocked agents

After all agents return, check if any reported `"result": "blocked"`. If so:

1. Show the user the screenshot(s) from the blocked agent(s).
2. Ask the user: **"One or more scenarios hit a login screen. Please provide credentials (username and password) to continue, or type 'skip' to mark these scenarios as skipped."**
3. Wait for the user's response.
4. If the user provides credentials, re-spawn ONLY the blocked agents with the same scenario prompt but prepend these additional steps before navigation:
   ```
   ## Pre-navigation: Log in first
   The app requires authentication. Before navigating to your test scenario:
   1. sim --device <UDID> layout-map  — confirm you are on the login screen
   2. Tap the username/email field, then type the credentials:
      sim --device <UDID> tap-element "<email_field_label>" && sim --device <UDID> type "<USERNAME>"
   3. Tap the password field and type the password:
      sim --device <UDID> tap-element "<password_field_label>" && sim --device <UDID> type "<PASSWORD>"
   4. Tap the sign-in/login button:
      sim --device <UDID> tap-and-wait "<login_button_label>"
   5. Wait for the home/main screen to load before proceeding with your scenario.
   ```
5. If the user says "skip", change those agents' results to `"result": "skipped"` with note "Login required — skipped by user".
6. Wait for re-spawned agents to complete, then proceed to Phase 5.

---

## Phase 5 — Aggregate & Post PR Comment

Upload all screenshots. Use a project-specific upload script if available, otherwise attach via `gh` CLI:
```bash
# Upload screenshots — use project upload script if available, else gh CLI
if [[ -x "./Scripts/github_upload_image.py" ]]; then
  python3 ./Scripts/github_upload_image.py <image_path>
elif command -v gh &>/dev/null; then
  # Attach screenshot as a PR comment image (user-attachments)
  echo "![screenshot](<local_path>)"
fi
```

Note: Screenshot upload to GitHub CDN is project-specific. If neither method works, reference screenshots by local path in the PR comment and note they are available locally.

Post one unified comment:
```bash
gh pr comment <PR_NUMBER> --repo "$REPO" --body "$(cat <<'COMMENT'
## QA Testing — <PR_TITLE>

**Branch:** `<BRANCH_NAME>` · **Devices:** <list all> · **Agents:** <total> ran in parallel

---

### Build
✅ Clean build — no errors

---

### Test Results

| # | Scenario | iPhone | iPad | Notes |
|---|---|---|---|---|
| 1 | <scenario> | ✅ Pass / ❌ Fail / ⚠ Skipped | ✅ / ❌ / ⚠ / N/A | <note> |

---

### Screenshots

<group by scenario, one row per scenario, iPhone left / iPad right>

| Scenario | iPhone | iPad |
|---|---|---|
| <scenario> | ![iPhone](<url>) | ![iPad](<url>) |

---

<overall verdict>
COMMENT
)"
```

**Comment rules:**
- One row per scenario — iPhone and iPad results side by side
- If a scenario was only tested on iPhone, iPad column = N/A
- If a simulator WDA failed, that cell = ⚠ Skipped (WDA unavailable)
- Mark ⚠ Skipped with reason if scenario required state you couldn't reach

---

## Phase 6 — Cleanup

```bash
git checkout "$BASE_BRANCH"
osascript -e 'display notification "QA complete — PR #<N> comment posted" with title "qa-branch ✅" sound name "Glass"'
```

---

## Key Constants

- **sim tool:** `SIM=$(which sim)` — resolved in Phase 0a; all sim commands use `$SIM`
- **Repo:** `REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')`
- **Project:** `XCODEPROJ=$(find . -maxdepth 2 -name "*.xcodeproj" | head -1)`
- **Scheme:** `SCHEME=$(basename "$XCODEPROJ" .xcodeproj)`
- **App path:** `find ~/Library/Developer/Xcode/DerivedData -maxdepth 5 -name "${APP_NAME}.app" -path "*/Debug-iphonesimulator/*" | head -1`
- **Bundle ID:** `defaults read "$APP_PATH/Info.plist" CFBundleIdentifier`
- **Port convention:** iPhones → 8100, 8101, 8102, ... | iPads → 8200, 8201, 8202, ...

---

## Error Handling

| Failure | Action |
|---|---|
| Build fails after retry | Stop, report errors, do NOT test |
| WDA fails to start for one simulator | Skip that scenario, mark ⚠ Skipped, continue with others |
| All iPhone WDA fail | Stop entirely — cannot QA without iPhone |
| layout-map returns `{"error":"WDA unavailable"}` | WDA fully down — agent should try wda-start or mark ⚠ Skipped |
| Not enough simulators for scenario count | Reuse same UDID for multiple scenarios (agents run sequentially on shared UDID then) |
| Agent returns no JSON | Mark that scenario ⚠ Skipped (agent failure), note in comment |
