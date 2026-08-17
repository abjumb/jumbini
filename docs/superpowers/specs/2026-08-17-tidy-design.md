# Tidy Design

**Status:** Approved for implementation  
**Date:** 17 August 2026  
**Product source:** `.context/attachments/uL8xvg/prd-desktop-tidy.md`

## Scope and decisions

Tidy lets Jumba move matching items from one user-selected folder into
subfolders of that folder. It is off until the user chooses a folder, previews
the proposed moves, and confirms a pass. The feature never deletes, trashes,
uploads, edits, compresses, or freely renames an item. A collision suffix is
the only permitted rename.

The PRD's release-date restriction is superseded for this implementation. The
complete P0 is in scope, including the idle trigger. All safety and permission
requirements remain in force.

The pickup animation uses a deterministic plausible screen region. Tidy does
not parse Finder's undocumented `.DS_Store` layout and does not request
Accessibility access.

Tidy examines immediate children of the selected folder. It does not recurse
into ordinary directories, including subfolders created as destinations.
Packages such as `.app`, `.rtfd`, and `.photoslibrary` are considered single,
indivisible candidates. This boundary prevents a sorted item from being picked
up repeatedly and keeps the user's folder tree outside the selected root out of
scope.

## Architecture

Tidy is an in-process feature with narrow layers. The filesystem engine has no
dependency on AppKit panels or SpriteKit animation.

### TidyRuleEngine

The rule engine is a pure function. It receives immutable item metadata and an
ordered rule list, then returns the first matching rule or no match. A rule has
an enabled state, a stable identifier, an `all` or `any` condition mode, one or
more conditions, and a destination subfolder name.

Conditions supported in the first version are:

- kind: Image, Screenshot, Document, Archive, Installer, Video, Audio, or Other;
- filename contains, compared case-insensitively;
- extension is one of, normalized without leading periods and compared
  case-insensitively;
- modified more than a positive number of days ago; and
- larger than a positive number of megabytes.

Unmatched and disabled-rule items are never moved. Screenshot classification
precedes the broader image classification so the default ordered presets send
screenshots to `Screenshots` and remaining images to `Images`.

### TidyStore

Rules are persisted as formatted, stable-key JSON under
`~/Library/Application Support/Jumbini/`. The JSON includes a schema version
and remains readable and hand-editable. On malformed input, Tidy disables live
runs, preserves the unreadable file for diagnosis, and surfaces the parse
error; it does not silently replace user rules.

The security-scoped folder bookmark is persisted separately from the readable
rules. Forgetting the folder deletes the bookmark and all derived folder state,
including undo availability, but does not remove the user's files or ledger.

The default rules, in order, are Screenshots to `Screenshots`, Images to
`Images`, Installers (`dmg` and `pkg`) to `Installers`, and Archives to
`Archives`. The fifth preset is the explicit unmatched behavior: leave
everything else alone. The moving presets become live only after the initial
preview is reviewed and confirmed.

### TidyPlanner

The planner enumerates only immediate children of the resolved folder root. It
skips ordinary directories, hidden implementation files, aliases, symbolic
links, and items that cannot be read safely. It treats packages as candidate
items without descending into them.

For each candidate, the planner reads only filesystem metadata needed by the
rules: name, extension, uniform type, package/alias/symlink flags, byte size,
and modification date. It never reads file contents. It obtains one best-effort
snapshot of paths open by other processes for the pass.

Destination names must be one visible folder component. Empty names, `.`,
`..`, slashes, absolute paths, path separators, and names that normalize outside
the root are rejected. Both root and destination paths are standardized and
resolved through symbolic links before containment checks. Any configured
destination outside the selected root is a programming/configuration error
that invalidates the complete plan; preview and execution move nothing.

The planner protects files modified within the configured recency interval.
The default is five minutes and the minimum accepted value is one minute. It
calculates collision-free destinations by appending ` 2`, ` 3`, and so on
before the extension. It accounts for both existing directory entries and
other proposed moves in the same batch.

Planning is read-only. It creates no destination folder, ledger, recovery
journal, or other file.

### TidyExecutor

The executor accepts a reviewed plan and selected row identifiers. It first
preflights the whole selected batch, then revalidates each source immediately
before its move:

- source identity and type still match the preview;
- the source and destination remain within the resolved root;
- the source is not a symlink or alias;
- the modification time is outside the recency window;
- the source is not in the pass's detectable-open-file set; and
- the destination remains unoccupied.

A changed source is skipped. A changed collision is assigned the next safe
suffix. A containment violation aborts before any move; a violation discovered
after execution starts stops at the current file boundary and records the
failure.

The executor creates destination folders on demand only after confirmation.
It uses `FileManager.moveItem` on the same selected volume and never implements
a copy-then-delete fallback. It never overwrites. At most 50 items move in one
pass. If more selected items remain, the pass completes after item 50 and
reports that the safety cap was reached.

Execution is serial on a dedicated queue. The coordinator can request a halt;
the executor observes that request between files, never during one filesystem
operation. A partial pass caused by a halt or unexpected move error remains a
valid, undoable pass containing exactly the completed moves.

### TidyLedger and recovery journal

The human-readable append-only ledger lives at
`~/Library/Application Support/Jumbini/tidy.log`. It records timestamp, pass
identifier, action, source, destination, matching rule, and result. Moves,
skips, failures, cap notices, and reversals are represented explicitly.

Before the first mutation, the executor atomically writes a machine-readable
last-pass recovery journal. Before each move it persists the intended source
and destination; after the move it marks the entry complete. If the journal
cannot be created, the pass fails closed. The journal is sufficient to
reconcile a process interruption even when a final ledger append failed.

At launch, reconciliation compares source and destination existence for an
unfinished entry. It never guesses when both or neither exist; it disables
further runs and surfaces a recovery error. When exactly one path contains the
expected item, it repairs the journal and missing audit entry conservatively.

Only the latest pass is undoable, including a halted partial pass. Starting a
new pass replaces that eligibility. Undo preflights every completed move in
reverse order. If any original source path is occupied or a destination item
no longer matches the recorded identity, undo aborts without moving anything.
During undo, an unexpected error triggers a best-effort roll-forward of already
reversed entries so the system does not knowingly leave a half-undone pass.
The journal and ledger record the outcome. Successful undo restores every item
to its exact source path and consumes undo eligibility.

### TidyCoordinator

The main-thread coordinator owns feature state and composes the store, planner,
executor, panels, trigger state, and animation sink. It is the only layer that
starts a pass.

The coordinator tracks whether a preview is required. Initial setup, any rule
change, rule reorder, condition change, destination change, recency change, or
folder change sets `needsPreview`. Manual and idle live runs are blocked until
a preview has been viewed and confirmed. Cancelling a preview preserves the
gate.

The coordinator resolves the bookmark and balances security-scope access for
the full planning/execution lifetime. A stale or revoked bookmark disables
Tidy and asks the user to choose a folder again. Declining affects no other
Jumbini behavior.

## User interface

The existing AppKit `JumbiniPanel` visual system is reused rather than adding a
second window framework.

The status menu gains a `Tidy` submenu with short native menu labels:

- `Set Up Tidy…` before a folder is selected, otherwise `Tidy Up…`;
- `Undo Last Tidy` with the completed move count when available;
- `Tidy Settings…`;
- `Tidy While Idle`, off by default and unavailable before a successful manual
  pass; and
- `Forget Folder…`.

The settings panel uses the established sidebar/card language. It shows the
selected folder, ordered rules, the recency interval, and idle interval. Rule
rows support enable/disable, reorder, add, edit, and remove. The rule editor
uses condition-specific controls and exposes `all`/`any` explicitly. Any edit
marks the rules as needing preview immediately.

The preview panel is scrollable and shows the full source and destination path
for every proposed move. Each movable row has a checkbox. Skipped items and
their reasons are visible but not selectable. The panel shows when the plan
exceeds 50 items. Cancel performs no writes. `Let Jumba tidy` executes only
selected movable rows after full revalidation.

Noninteractive idle-run results use a compact notice rather than stealing
focus with a modal alert. Notices summarize moved, skipped, failed, halted, and
capped counts. The ledger is the detailed audit trail.

## Animation

Animation is an optional observer of successful filesystem results. The
executor never waits for it and receives no state back from it.

After a successful move, the coordinator may enqueue a scene cue. Jumba moves
toward a deterministic plausible region within the active display, plays the
existing carry frames, and performs the existing deposit animation. The first
few moves are represented individually; remaining moves are visually batched
to keep a 50-item pass brief.

When the overlay is paused or hidden, when macOS Reduce Motion is enabled, or
when the scene cannot accept a cue, the cue is dropped. No alternate filesystem
path exists for these cases because filesystem execution has already succeeded
independently.

## Triggers and system state

Manual Tidy is available whenever a folder is configured. When preview is
required, invoking it opens preview instead of executing directly.

Idle Tidy defaults off and cannot be enabled before one successful manual pass.
Its default threshold is ten minutes. It reuses the existing `SystemMonitor`
idle state: an idle-began signal schedules the remaining interval, and an
idle-ended signal cancels a pending pass or requests a file-boundary halt for
an executing pass.

The coordinator also observes workspace session and display notifications.
A locked/resigned session or sleeping display cancels pending idle work and
prevents a new idle pass. Waking the display does not itself start one; a fresh
eligible idle interval is required.

No file-add watcher, real-time trigger, schedule, recursive scan, second folder,
content-aware classification, or rule synchronization is included.

## Error behavior

- A malformed or unsafe rule disables execution until corrected and previewed.
- A stale bookmark requests folder selection and leaves the rest of Jumbini
  unchanged.
- A planner containment error invalidates the entire plan and moves nothing.
- Failure to persist the recovery journal prevents all mutation.
- A source changed after preview is skipped and logged.
- An unexpected move failure stops the pass at a file boundary. Completed moves
  remain undoable.
- A ledger write failure after a move is repaired from the recovery journal on
  launch.
- An undo preflight conflict moves nothing. An unexpected mid-undo failure
  triggers roll-forward and is surfaced prominently.
- Animation, overlay, and Reduce Motion state cannot fail or delay a file move.

## Verification strategy

Implementation follows red-green-refactor. Production behavior is introduced
only after a focused test has failed for the expected missing behavior.

Pure tests cover:

- every condition and `all`/`any` composition;
- ordered first-match wins and disabled rules;
- unmatched items never move;
- kind and screenshot classification;
- destination validation and normalized containment;
- collision naming; and
- preview-gate and idle-trigger state transitions.

Temporary-directory integration tests use real filesystem moves to cover:

- preview performs zero writes;
- recent items, aliases, symlinks, directories, packages, and detectable open
  files;
- destination creation only during execution;
- existing and within-batch name collisions;
- 50 moves from a 4,000-item matching set;
- source mutation between preview and execution;
- path-escape attempts;
- journal and ledger failure injection;
- process-interruption reconciliation;
- exact-path undo and undo preflight conflicts; and
- halt-at-boundary behavior.

Coordinator and UI tests cover default presets, rule edits restoring the
preview gate, row opt-outs, manual-success gating of idle settings, menu state,
and reduced-motion/paused animation suppression. Existing panel snapshot tools
capture the Tidy settings and preview panels.

Completion requires:

1. the complete Swift test suite;
2. a debug and release build;
3. app-bundle assembly;
4. the bundled-app smoke test; and
5. manual checks for folder selection and relaunch, preview cancellation,
   pause, Reduce Motion, session lock/display sleep, user return during an idle
   pass, and exact undo.

## Shipping boundary

The implementation may be committed and prepared for review from the current
Conductor workspace. Publishing a tag or GitHub release remains a separate,
explicit external action because it triggers signing, notarization, Sparkle
appcast publication, and distribution to existing users.
