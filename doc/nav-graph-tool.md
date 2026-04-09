# Navigation Graph Tool — Design Plan

## Overview

A lazy, incremental navigation graph tool for the Mindvalley iOS project.
Agents record navigation paths as they encounter them. Over time, the disconnected
subgraphs merge into a full navigation map of the app.

Multiple agents run in parallel — some reading, some writing — so the storage
layer must handle concurrent multi-process access safely.

---

## Core Concepts

### What a Node Is

A **node** is a screen. It has an identity, a type (SwiftUI view vs UIViewController
vs modal), and a list of **actions** a user can perform on it.

Actions fall into two categories:
- **Navigation actions** — result in a transition to another node (create an edge)
- **State actions** — change state on the same screen (toggle filter, play/pause, etc.)

Both are stored on the node, but only navigation actions produce edges in the graph.

### What an Edge Is

A directed connection from one node to another, annotated with:
- The action that triggers it (tap a button, swipe down, etc.)
- The transition style (push, modal, sheet, tab switch, etc.)
- Optional conditions (requires auth, feature flag, etc.)

### What a Path Is

A sequence of (node, action) pairs leading from a source node to a destination.
Not just a list of node IDs — an agent needs to know *what to do* at each step.

---

## How sim.sh Identifies and Interacts with Elements

`sim.sh` was fully rewritten to use **WebDriverAgent (WDA)** as its primary backend.
This shapes how actions and element locators must be modelled.

### WDA Element Identification

WDA exposes the app's accessibility tree via `GET /session/{id}/source` as XML.
Each element has two relevant attributes:

| Attribute | What it is | Example | Priority |
|---|---|---|---|
| `label` | Human-readable visible text | `"Close"`, `"Meditations"`, `"Pause"` | **Preferred** |
| `name` | Internal accessibility identifier | `"TabBar.Meditations.Item"`, `"closeButton"` | Fallback |

`label` is preferred because it matches what a user sees. `name` is an internal
string set by the developer — sometimes it matches the label, sometimes it's a
coded identifier, sometimes it's empty.

WDA element types (`XCUIElementTypeButton`, `XCUIElementTypeTextField`, etc.) can
additionally disambiguate when label or name are ambiguous.

### Coordinate Space

All coordinates in WDA are **iOS logical points** (e.g. 393×852 for iPhone 16).
`sim.sh` accepts and returns these directly — no pixel or macOS-screen conversion
needed. Tab bar item centers come from `layout-map navigation.tabs[].x/y`.
Back button center comes from `layout-map navigation.back.x/y`.

### sim.sh Interaction Commands → Action Type Mapping

| `actions[].type` | sim.sh command | Notes |
|---|---|---|
| `tap` | `sim.sh tap <x> <y>` | Preferred after scroll; uses WDA tap at iOS logical coords |
| `tap` (by label) | `sim.sh tap-element <label>` | Safe only on non-scrolled screens (no cross-tab pollution) |
| `double_tap` | `sim.sh tap <x> <y>` twice | No native double-tap command; send two taps |
| `long_press` | (not yet in sim.sh) | Record as `long_press`; executor handles via WDA W3C actions |
| `swipe_up` | `sim.sh scroll-up` | WDA swipe gesture |
| `swipe_down` | `sim.sh scroll-down` | WDA swipe gesture |
| `swipe_left` | `sim.sh swipe <x1> <y1> <x2> <y2>` | WDA swipe |
| `swipe_right` | `sim.sh swipe <x1> <y1> <x2> <y2>` | WDA swipe |
| `pull_to_refresh` | `sim.sh swipe` (downward from top) | Same as swipe_down from top edge |
| `back` | `sim.sh tap <back_x> <back_y>` | Coords from `layout-map navigation.back` |
| `tab_switch` | `sim.sh tap <tab_x> <tab_y>` | Coords from `layout-map navigation.tabs[]` |
| `scroll_to_reveal` | `sim.sh scroll-to-visible <label>` | Internal loop; single bash call |
| `deep_link` | (sim.sh not involved) | URL scheme / xcrun simctl openurl |
| `notification_tap` | (sim.sh not involved) | Push notification tap is out of WDA scope |
| `shake` | (sim.sh not involved) | `xcrun simctl io … shake` |

### Critical WDA Behaviour Notes

1. **`tap-element` uses viewport-only search** (`/source` XML). It only finds
   elements currently visible in the viewport — avoids cross-tab pollution where
   background tabs have the same label.

2. **After `scroll-to-visible`, always use coordinate tap**, not `tap-element`.
   `scroll-to-visible` returns the element's `{x, y, w, h}` in its JSON result.
   Use `tap x+w/2 y+h/2` from that result — this is the only safe approach on
   scrollable screens.

3. **Tab bar items are coordinate-only**. WDA `/source` does include tab bar items,
   but `layout-map navigation.tabs[]` is the reliable way to get their centers.
   Always use coordinates for tab switches, never `tap-element`.

4. **Screen identification uses `layout-map`**. The `navigation.title` field in
   `layout-map` output is the current screen's nav bar title. Screens without a
   nav bar (tab roots) are identified by their fingerprint elements instead.

---

## Data Model

### Node

```json
{
  "id": "MeditationPlayerView",
  "label": "Meditation Player",
  "type": "swiftui_view",
  "module": "NextGen/Screens/MeditationPlayer",
  "is_root": false,
  "fingerprint": {
    "nav_title": "Meditation Player",
    "required_elements": [
      {"strategy": "label", "value": "Pause"},
      {"strategy": "label", "value": "Play"}
    ]
  },
  "metadata": {
    "file_path": "Mindvalley/NextGen/Screens/MeditationPlayer/MeditationPlayerView.swift",
    "requires_auth": true,
    "description": "Full-screen meditation playback screen"
  },
  "actions": [
    {
      "id": "action_tap_close",
      "type": "tap",
      "label": "Close Player",
      "locator": {
        "strategy": "label",
        "value": "Close"
      },
      "outcome_type": "navigation",
      "scroll_required": false
    },
    {
      "id": "action_swipe_down",
      "type": "swipe_down",
      "label": "Swipe down to dismiss",
      "locator": {
        "strategy": "coordinates",
        "x": 196,
        "y": 200
      },
      "outcome_type": "navigation",
      "scroll_required": false
    },
    {
      "id": "action_tap_play_pause",
      "type": "tap",
      "label": "Play / Pause",
      "locator": {
        "strategy": "label",
        "value": "Pause"
      },
      "outcome_type": "state_change",
      "scroll_required": false
    }
  ]
}
```

### Node: `fingerprint`

How an agent confirms it has arrived at this screen. Checked after a navigation
action completes (via `wait-for` + `layout-map`).

```json
"fingerprint": {
  "nav_title": "Meditation Player",
  "required_elements": [
    {"strategy": "label", "value": "Pause"},
    {"strategy": "label", "value": "Play"}
  ]
}
```

| Field | Meaning |
|---|---|
| `nav_title` | Expected `navigation.title` from `layout-map`. `null` for screens without a nav bar. |
| `required_elements` | One or more locators — at least one must be visible to confirm arrival |

For tab root screens (no nav title), `nav_title` is `null` and `required_elements`
carries the identification burden (e.g., `{"strategy": "label", "value": "Today"}`).

### Node: `actions[].locator`

Describes how sim.sh should find and interact with the element. Three strategies:

#### `strategy: "label"` — preferred for most interactive elements
```json
"locator": {
  "strategy": "label",
  "value": "Close",
  "wda_type": "XCUIElementTypeButton"
}
```
Maps to `sim.sh tap-element "Close"` (viewport-only WDA `/source` search).
`wda_type` is optional — only needed when multiple elements share the same label.

#### `strategy: "name"` — fallback when no visible label exists
```json
"locator": {
  "strategy": "name",
  "value": "closeButton",
  "wda_type": "XCUIElementTypeButton"
}
```
Maps to WDA `/elements` search by accessibility identifier (`name` attribute).
Use when the element has no human-readable label (icon-only buttons, etc.).

#### `strategy: "coordinates"` — for tab bar items and gesture-based actions
```json
"locator": {
  "strategy": "coordinates",
  "x": 46,
  "y": 820
}
```
Maps to `sim.sh tap <x> <y>`. Always used for:
- Tab bar items (coords from `layout-map navigation.tabs[]`)
- Back button (coords from `layout-map navigation.back`)
- Swipe/scroll gestures where start point matters
- Any element after `scroll-to-visible` (use result coords, never `tap-element`)

Coordinates are in **iOS logical points** and are screen-size specific.
Include the device model in `metadata` when storing coordinate-based locators.

#### `strategy: "back_button"` — semantic shorthand
```json
"locator": {
  "strategy": "back_button"
}
```
Agent resolves this at runtime via `layout-map navigation.back.x/y`. Device and
orientation independent — always works as long as a back button is visible.

### Node: `actions[].scroll_required`

Boolean. When `true`, the agent must scroll the element into view before tapping.
Use `scroll-to-visible "<label>"` and then tap using the returned coordinates,
not `tap-element`.

#### `type` values (node)
| Value | Meaning |
|---|---|
| `swiftui_view` | SwiftUI `View` |
| `uiviewcontroller` | UIKit `UIViewController` |
| `modal` | Presented modally (`.sheet`) |
| `full_screen_cover` | `.fullScreenCover` |
| `alert` | `Alert` / `UIAlertController` |
| `action_sheet` | Action sheet |
| `tab` | A root tab in a `TabView` / `UITabBarController` |
| `navigation_root` | Root of a navigation stack |

#### `is_root`
Marks the single root of the app (e.g. `HomeTabView` or `LaunchScreen`). Used as
the default source for path queries that don't specify a start node.

#### `actions[].type` values
| Value | Gesture | sim.sh command |
|---|---|---|
| `tap` | Single tap | `tap <x> <y>` or `tap-element <label>` |
| `double_tap` | Double tap | Two sequential `tap` calls |
| `long_press` | Long press | WDA W3C pointer actions (future) |
| `swipe_left` | Swipe left | `swipe <x1> <y1> <x2> <y2>` |
| `swipe_right` | Swipe right | `swipe <x1> <y1> <x2> <y2>` |
| `swipe_up` | Swipe up / scroll down | `scroll-up` |
| `swipe_down` | Swipe down / scroll up | `scroll-down` |
| `pull_to_refresh` | Pull-to-refresh | `swipe` downward from top of scroll area |
| `pinch` | Pinch gesture | WDA W3C pointer actions (future) |
| `drag` | Drag/reorder | WDA W3C pointer actions (future) |
| `scroll_to_reveal` | Scroll until element visible | `scroll-to-visible "<label>"` |
| `shake` | Device shake | `xcrun simctl io … shake` |
| `deep_link` | URL / universal link | `xcrun simctl openurl` |
| `notification_tap` | Tap push notification | Out of WDA scope |
| `back` | Native back button or swipe-back | `tap` using `layout-map navigation.back` coords |
| `tab_switch` | Tab bar item tap | `tap` using `layout-map navigation.tabs[]` coords |

#### `actions[].outcome_type` values
| Value | Meaning |
|---|---|
| `navigation` | Transitions to another screen → produces an edge |
| `state_change` | Mutates UI state on the same screen |
| `dismiss` | Closes the current screen (back/dismiss) |
| `external` | Opens Safari, system sheet, etc. |

---

### Edge

```json
{
  "from_node": "TodayFeedView",
  "to_node": "MeditationPlayerView",
  "action_type": "tap",
  "action_label": "Tap meditation card",
  "locator": {
    "strategy": "label",
    "value": "Speak and Inspire",
    "wda_type": "XCUIElementTypeCell"
  },
  "scroll_required": true,
  "transition": "full_screen_cover",
  "conditions": ["requires_auth"],
  "confidence": 1.0,
  "source": "agent_recorded"
}
```

The edge carries its own `locator` and `scroll_required` — this is the same
information as the triggering action on the source node. An agent following a
path only needs the edge data (plus the destination's `fingerprint`) to execute
a step; it does not need to load the full source node.

#### `transition` values
| Value | Meaning |
|---|---|
| `push` | Navigation stack push |
| `modal` | `.sheet` presentation |
| `full_screen_cover` | `.fullScreenCover` |
| `replace` | Replace root / page swap |
| `tab_switch` | Tab bar tab selection |
| `pop` | Back navigation |
| `dismiss` | Dismiss a presented sheet/modal |
| `deep_link` | Entered via deep link |

#### `confidence` (0.0 – 1.0)
Agents recording lazily may be uncertain. Static analysis or manual entries use 1.0.
Low-confidence edges can be flagged for verification.

#### `source` values
| Value | Meaning |
|---|---|
| `agent_recorded` | Discovered at runtime by an agent |
| `static_analysis` | Seeded from regex/AST scan |
| `manual` | Added explicitly by a developer |

---

### Path (query result)

A path is a sequence of steps. Each step tells an agent:
1. What screen it should currently be on (`fingerprint` to verify)
2. What action to perform to advance (`action_type`, `locator`, `scroll_required`)
3. What transition to expect (`transition`)

The final step has no action — the agent has arrived.

```json
{
  "destination": "MeditationPlayerView",
  "source": "HomeTabView",
  "paths": [
    {
      "steps": [
        {
          "node_id": "HomeTabView",
          "node_label": "Home Tab",
          "fingerprint": {
            "nav_title": null,
            "required_elements": [{"strategy": "label", "value": "Today"}]
          },
          "action": {
            "type": "tab_switch",
            "label": "Tap Today tab",
            "locator": {"strategy": "coordinates", "x": 78, "y": 820},
            "scroll_required": false
          },
          "transition": "tab_switch"
        },
        {
          "node_id": "TodayFeedView",
          "node_label": "Today Feed",
          "fingerprint": {
            "nav_title": "Today",
            "required_elements": [{"strategy": "label", "value": "Good morning"}]
          },
          "action": {
            "type": "tap",
            "label": "Tap Speak and Inspire card",
            "locator": {
              "strategy": "label",
              "value": "Speak and Inspire",
              "wda_type": "XCUIElementTypeCell"
            },
            "scroll_required": true
          },
          "transition": "full_screen_cover"
        },
        {
          "node_id": "MeditationPlayerView",
          "node_label": "Meditation Player",
          "fingerprint": {
            "nav_title": "Meditation Player",
            "required_elements": [{"strategy": "label", "value": "Pause"}]
          },
          "action": null
        }
      ],
      "length": 2,
      "confidence": 1.0
    }
  ]
}
```

`confidence` for a path is the product of all edge confidences along the path.
Multiple paths are returned in ascending order of length (shortest first).

### How an Agent Executes a Path Step

For each non-final step:

```
1. Verify current screen:
   - Run layout-map
   - Check navigation.title == fingerprint.nav_title (if not null)
   - Check at least one required_element is visible in layout-map interactive list
   - If mismatch: abort or re-navigate to correct screen

2. If action.scroll_required:
   - Run: scroll-to-visible "<locator.value>"
   - Capture returned {x, y, w, h}
   - Compute tap coords: cx = x + w/2, cy = y + h/2
   - Run: tap cx cy

3. If not scroll_required:
   - strategy "label"      → tap-element "<locator.value>"
   - strategy "name"       → tap via WDA /elements by name, then tap coords
   - strategy "coordinates"→ tap <locator.x> <locator.y>
   - strategy "back_button"→ read layout-map navigation.back.x/y, tap those coords

4. Wait for destination fingerprint:
   - Run: wait-for "<destination.fingerprint.required_elements[0].value>" 10
   - Then verify full fingerprint via layout-map
```

---

## Storage Architecture

**SQLite (WAL mode) + in-process NetworkX for queries**

- SQLite is the source of truth — persistent, multi-process safe
- NetworkX is a transient query layer — loaded per query, never persisted
- WAL mode allows unlimited concurrent readers with one serialized writer
- `busy_timeout = 5000ms` so writer contention queues instead of failing

### Schema

```sql
CREATE TABLE nodes (
    id          TEXT PRIMARY KEY,
    label       TEXT NOT NULL,
    type        TEXT NOT NULL DEFAULT 'swiftui_view',
    module      TEXT,
    is_root     INTEGER NOT NULL DEFAULT 0,
    fingerprint TEXT NOT NULL DEFAULT '{}',   -- JSON: {nav_title, required_elements}
    metadata    TEXT NOT NULL DEFAULT '{}',   -- JSON: arbitrary key/value pairs
    actions     TEXT NOT NULL DEFAULT '[]',   -- JSON: action list (see Action schema)
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE edges (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    from_node       TEXT NOT NULL REFERENCES nodes(id),
    to_node         TEXT NOT NULL REFERENCES nodes(id),
    action_type     TEXT NOT NULL,             -- tap, swipe_down, tab_switch, back, etc.
    action_label    TEXT,                      -- human description, e.g. "Tap Close button"
    locator         TEXT NOT NULL DEFAULT '{}',-- JSON: {strategy, value?, x?, y?, wda_type?}
    scroll_required INTEGER NOT NULL DEFAULT 0,-- 1 = must scroll-to-visible before tap
    transition      TEXT NOT NULL DEFAULT 'push',
    conditions      TEXT NOT NULL DEFAULT '[]',-- JSON array of strings
    confidence      REAL NOT NULL DEFAULT 1.0,
    source          TEXT NOT NULL DEFAULT 'agent_recorded',
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(from_node, to_node, action_type, locator)
);

CREATE INDEX idx_edges_from  ON edges(from_node);
CREATE INDEX idx_edges_to    ON edges(to_node);
```

`UNIQUE(from_node, to_node, action_type, locator)` means `INSERT OR IGNORE`
is safe — recording the same navigation twice is idempotent. The `locator` JSON
blob is the uniqueness discriminator (two different buttons on the same screen that
both navigate to the same destination produce two distinct edges).

---

## API Design

The tool is a Python module: `nav_graph.py` (or `nav_graph/` package).

```python
from nav_graph import NavGraph

g = NavGraph("nav_graph.db")
```

### Operations

```python
# --- Write operations ---

# Record a navigation encounter (idempotent, safe to call repeatedly)
g.record_navigation(
    from_node="TodayFeedView",
    to_node="MeditationPlayerView",
    action_type="tap",
    action_label="Tap Speak and Inspire card",
    locator={
        "strategy": "label",          # "label" | "name" | "coordinates" | "back_button"
        "value": "Speak and Inspire", # WDA label attribute
        "wda_type": "XCUIElementTypeCell"  # optional disambiguation
    },
    scroll_required=True,
    transition="full_screen_cover",
    confidence=1.0,
    source="agent_recorded"
)

# Create or update a node explicitly
g.upsert_node(
    id="MeditationPlayerView",
    label="Meditation Player",
    type="swiftui_view",
    module="NextGen/Screens/MeditationPlayer",
    is_root=False,
    fingerprint={
        "nav_title": "Meditation Player",
        "required_elements": [{"strategy": "label", "value": "Pause"}]
    },
    metadata={"file_path": "...", "requires_auth": True},
    actions=[
        {
            "id": "action_tap_close",
            "type": "tap",
            "label": "Close Player",
            "locator": {"strategy": "label", "value": "Close"},
            "outcome_type": "navigation",
            "scroll_required": False
        },
        {
            "id": "action_back",
            "type": "back",
            "label": "Swipe back / tap back button",
            "locator": {"strategy": "back_button"},
            "outcome_type": "dismiss",
            "scroll_required": False
        }
    ]
)

# Remove a node and all its edges
g.remove_node("MeditationPlayerView")

# Remove a specific edge
g.remove_edge(
    from_node="TodayFeedView",
    to_node="MeditationPlayerView",
    action_type="tap",
    action_element="meditationCard"
)

# --- Read operations ---

# Get all paths from root (or a specified source) to a destination
# Returns list of Path objects, shortest first
paths = g.find_paths(
    destination="MeditationPlayerView",
    source=None,          # None = use the node where is_root=True
    max_depth=10,         # prevent infinite loops in cyclic graphs
    max_paths=5           # cap result count
)

# Get immediate next destinations reachable from a node
next_steps = g.next_from("TodayFeedView")
# Returns: list of {edge, to_node} dicts

# Get a node and its full action list
node = g.get_node("MeditationPlayerView")

# List all known nodes (useful for agents to see what's mapped)
all_nodes = g.list_nodes()

# Check if a node exists
exists = g.has_node("MeditationPlayerView")
```

### Return types

All return types are plain Python dicts/lists (JSON-serializable) so agents can
forward results over stdout, tool calls, or MCP responses without serialization work.

---

## Concurrency Model

| Scenario | Behaviour |
|---|---|
| Multiple agents reading simultaneously | Safe — WAL mode, unlimited concurrent readers |
| One agent writing, others reading | Safe — readers see the last committed snapshot |
| Two agents writing simultaneously | One waits up to 5 seconds, then proceeds; no data loss |
| Agent crashes mid-write | SQLite rolls back the incomplete transaction automatically |
| Agent crashes mid-read | No side effects, no locks held |

Write transactions are kept as short as possible — a `record_navigation` call is
a single `INSERT OR IGNORE` pair, completing in microseconds.

---

## Project Structure

```
tools/
└── nav_graph/
    ├── __init__.py         # re-exports NavGraph class
    ├── nav_graph.py        # NavGraph class: all operations
    ├── schema.py           # SQL schema strings and migration helpers
    ├── models.py           # Python dataclasses: Node, Edge, Action, Path, Step
    ├── query.py            # NetworkX-backed path query logic
    └── cli.py              # Optional CLI: nav_graph record / find / list / remove
```

The database file lives wherever the caller specifies. For project-wide use, a
sensible default is `tools/nav_graph/data/nav_graph.db` (gitignored).

---

## CLI (optional convenience layer)

```bash
# Record a navigation
python -m nav_graph record --from TodayFeedView --to MeditationPlayerView \
    --action tap --element meditationCard --transition full_screen_cover

# Find all paths to a destination
python -m nav_graph find --destination MeditationPlayerView

# List immediate next steps from a node
python -m nav_graph next --from TodayFeedView

# List all known nodes
python -m nav_graph list

# Remove a node
python -m nav_graph remove --node MeditationPlayerView

# Dump the graph as Mermaid (for docs)
python -m nav_graph export --format mermaid
python -m nav_graph export --format dot
```

---

## Implementation Phases

### Phase 1 — Core (build first)
- [ ] Schema creation and migration helpers (`schema.py`)
- [ ] `NavGraph` class with `record_navigation`, `upsert_node`, `remove_node` (`nav_graph.py`)
- [ ] `find_paths` using NetworkX BFS (`query.py`)
- [ ] `next_from` using direct SQLite query (`nav_graph.py`)
- [ ] WAL config, `busy_timeout`, connection setup
- [ ] `models.py` dataclasses

### Phase 2 — Usability
- [ ] CLI (`cli.py`) for manual inspection and recording
- [ ] `export --format mermaid` and `export --format dot` for documentation
- [ ] `confidence` threshold filtering on `find_paths`
- [ ] `list_nodes` and `has_node` helpers

### Phase 3 — Seeding (optional, future)
- [ ] Static analysis seed script: regex scan of `Mindvalley/Modules/` for UIKit patterns
- [ ] Static analysis seed script: SwiftSyntax scan of `Mindvalley/NextGen/Screens/`
- [ ] Storyboard XML parser for legacy navigation
- [ ] Batch import from seed scripts into the graph

### Phase 4 — Visualization (optional, future)
- [ ] Interactive HTML viewer using D3.js `d3-force`
- [ ] Click a node → see its actions and outgoing edges
- [ ] Highlight a path returned by `find_paths`

---

## Open Questions

1. **Root node** — Is there always exactly one root? The app may have multiple entry
   points (deep links, push notification launch). Should `is_root` be a flag on many
   nodes, or should the caller always specify `source` in `find_paths`?

2. **Back edges** — Should "go back" transitions be recorded as edges pointing back to
   the parent? This creates cycles. NetworkX handles cycles but `all_simple_paths`
   naturally avoids revisiting nodes, so this is safe. Decision: record back edges
   only if they lead to a *different* node than the navigation parent (e.g. dismissing
   a modal to a different screen than where you came from).

3. **Dynamic destinations** — Some navigations are data-driven (tap a quest card → go
   to whichever quest was in the card). Record these as a single generic edge to a
   template node (e.g. `QuestDetailView`) with a note in `metadata`.

4. **Action uniqueness** — The edge uniqueness key is `(from, to, action_type, element)`.
   If two different elements on the same screen both navigate to the same destination,
   they produce two edges. This is correct behaviour — both paths are valid.
