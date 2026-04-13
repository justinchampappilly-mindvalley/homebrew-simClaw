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

## Phase 0 — Gather Inputs

**Required:** Extract the PR number from the user's message. If not provided, ask for it.

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
# List all available iPhones and iPads
xcrun simctl list devices available | grep -E "iPhone [0-9]+" | head -10
xcrun simctl list devices available | grep -E "iPad" | head -10
```

Collect UDIDs into two lists:
- `IPHONE_UDIDS[]` — one per iPhone scenario needed (use different iPhone models if available; reuse same model with different UDIDs if not)
- `IPAD_UDIDS[]` — one per iPad scenario needed (only if `IPAD_NEEDED=true`)

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
SIM="/opt/homebrew/bin/sim"
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 5 \
  -name "${APP_NAME}.app" -path "*/Debug-iphonesimulator/*" | head -1)
echo "App: $APP_PATH"
```

### 3c. Setup one simulator per scenario (sequential to avoid WDA port collisions)

Run `sim setup` for each simulator in order. Each call blocks until WDA is ready.

```bash
# iPhone simulators — one per iPhone scenario
$SIM --device <IPHONE_UDIDS[0]> setup "$APP_PATH" --port 8100
$SIM --device <IPHONE_UDIDS[1]> setup "$APP_PATH" --port 8101
$SIM --device <IPHONE_UDIDS[2]> setup "$APP_PATH" --port 8102
# ... repeat for each iPhone scenario

# iPad simulators — one per iPad scenario (if IPAD_NEEDED)
$SIM --device <IPAD_UDIDS[0]> setup "$APP_PATH" --port 8200
$SIM --device <IPAD_UDIDS[1]> setup "$APP_PATH" --port 8201
$SIM --device <IPAD_UDIDS[2]> setup "$APP_PATH" --port 8202
# ... repeat for each iPad scenario
```

The sim tool now patches `USE_PORT` into a temp xctestrun copy via PlistBuddy, so each simulator binds to its own unique port.

### 3d. WDA health check — verify every simulator before spawning agents
```bash
# Check all iPhone simulators
$SIM --device <IPHONE_UDIDS[0]> health-check && echo "iPhone[0] OK" || echo "iPhone[0] FAILED"
$SIM --device <IPHONE_UDIDS[1]> health-check && echo "iPhone[1] OK" || echo "iPhone[1] FAILED"
# ... one per simulator

# Check all iPad simulators
$SIM --device <IPAD_UDIDS[0]> health-check && echo "iPad[0] OK" || echo "iPad[0] FAILED"
# ...
```

- Any iPhone WDA FAILED → skip that scenario, mark ⚠ Skipped in PR comment
- All iPhone WDA FAILED → stop entirely
- Any iPad WDA FAILED → skip that iPad scenario, mark ⚠ Skipped

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
SIM="/opt/homebrew/bin/sim"
BUNDLE_ID="<BUNDLE_ID>"
REPO="<REPO>"
Branch: <BRANCH_NAME>
App already installed and WDA running on port <PORT> — do NOT run setup.

## Navigation
Use sim commands for all interactions. sim tap now uses WDA pointer actions
internally — it works reliably on both iPhone and iPad. No need for raw curl.

Primary workflow:
1. sim --device <UDID> layout-map     — see what's on screen
2. sim --device <UDID> tap-and-wait "<label>" — tap + wait + get new layout-map
3. sim --device <UDID> screenshot <path>      — capture evidence

If tap-and-wait fails, try direct coordinates:
1. sim --device <UDID> find-element "<label>"  — get element coordinates
2. sim --device <UDID> tap <x> <y>             — tap at coordinates
3. sim --device <UDID> wait-for "<label>"      — wait for expected element

Other useful commands:
- sim --device <UDID> tap-element "<label>"    — tap by accessibility label
- sim --device <UDID> scroll-to-visible "<label>" — scroll until element visible
- sim --device <UDID> scroll-down / scroll-up  — manual scroll
- sim --device <UDID> type "<text>"            — type into focused field
- sim --device <UDID> wait-for-stable          — wait for screen to stabilize
- sim --device <UDID> describe                 — describe visible screen
- sim --device <UDID> screen-title             — get current screen title

## CRITICAL PERFORMANCE RULES
Each Bash tool call costs ~10s API latency. Always batch with &&.
- BAD:  sim tap-element "Login" / then / sim wait-for "Home" / then / sim screenshot path.png
- GOOD: sim tap-element "Login" && sim wait-for "Home" 10 && sim screenshot path.png  (one call)

Use sim tap-and-wait when possible — it does tap + wait + layout-map in ONE call.
layout-map has a built-in fallback for AX tree timeouts — no manual recovery needed.

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
  "result": "pass|fail|skipped",
  "note": "<one-line observation>",
  "screenshot": "/tmp/pr<N>-qa-<TIMESTAMP>/<SCENARIO_SLUG>/evidence.png"
}
```

### Wait for all agents

Wait for task-completion notifications from every spawned agent. Collect all JSON result objects. Do not post the PR comment until every agent has responded.

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
