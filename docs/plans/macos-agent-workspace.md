# Phase 2: macOS agent workspace

Status: **planned, not implemented**. Phase 1 promotes the existing example to the
official LangTools macOS/iOS app at `Apps/LangTools` without changing the core library.
This file is the handoff for focused follow-up PRs, not a claim of tmux functionality.

## Product scope

A native sidebar navigates **Projects** and **Tmux Sessions**. A project stores a root
folder, display name, notes, links/tags, launch profiles, and saved associations/layout.
Selecting a project shows its live agents as a single application-level window group;
selecting an agent shows its **interactive terminal**, not a transcript approximation.
The existing chat view remains available. Project groups may span multiple tmux sessions.

“Open Project” discovers and attaches to existing agents first. Launching missing agents
requires a user action and must not create duplicates on repeated opens. A group is
navigation metadata: opening one must not move or restart existing sessions/panes.
Closing a tab or the app detaches; stopping an agent is a separate confirmed action.

Local macOS tmux is the MVP. iOS retains chat and, later, shared project/conversation
views; it cannot host local tmux. SSH/remote Mac access, synchronization, native transcript
views, saved-conversation resume, advanced split layouts, and agent orchestration are later work.

## Integration boundaries

- Keep the shared SwiftUI entry point and chat functionality in `Apps/LangTools/Sources`.
  Introduce a macOS-only workspace shell through platform-specific views, preserving iOS.
- Put shared project metadata and canonical path matching in an app-owned module when
  first needed. Use versioned persistence; do not store credentials in project files.
- Isolate tmux process execution, discovery, and reconnection in a macOS-only service.
  Inject a protocol-backed command runner so tests do not touch the user's tmux server.
- Evaluate SwiftTerm in an AppKit-hosted view for terminal rendering/PTY interaction.
  Validate its API, license, lifecycle, accessibility, and agent TUI behavior before adoption.
- Agent adapters initially supply launch presets/identity hints for Pi, Claude Code,
  Codex, and arbitrary executables. They do not depend on undocumented history formats.
- No terminal/PTY dependencies in the core LangTools package or the iOS dependency graph.
  Do not introduce unused framework abstractions before the feasibility spike succeeds.

## Gate 1: sandbox and independent attachment spike

The current app is sandboxed. Prove a viable distribution/permission architecture for
executing local tmux, reaching its socket, accessing project folders, and managing PTYs.
Compare a deliberately separate direct-distribution macOS configuration with a narrowly
scoped helper design. Do not silently disable the existing app sandbox or add broad
entitlements. Document the selected approach and get approval before changing that boundary.

Tmux session groups share a window set; they are not arbitrary nested window groups.
The app must model server/socket + session ID + window ID + pane ID, not mutable names
or indexes alone. Detect stale identities after server restarts.

Prove a terminal can view/select its target without unexpectedly switching an existing
external client's active window. Evaluate isolated viewing sessions/window links, shared
window sizing, client resize behavior, and cleanup semantics. Never kill a linked window
as a shortcut for closing a viewer. Do not rewrite global tmux configuration.

**Acceptance:** real agent TUIs work (input, resize, scrolling, Unicode, shortcuts);
an external tmux client remains usable; multiple app viewers do not fight over selection;
closing/reopening the app preserves the agent; failed attachment reports an actionable error.
Use a disposable tmux socket for automated lifecycle tests. Resolve this gate before UI expansion.

## Gate 2: discovery and project matching

- Inventory live sessions/windows/panes through structured tmux queries; reconcile events
  with snapshots so missed events or temporary disconnects do not leave stale UI state.
- Match canonical paths by components, not string prefixes (`/repo` must not match `/repo2`).
  Resolve symlinks, handle spaces/Unicode, and prefer the most specific registered root.
- Include subdirectories; Git worktrees outside the root need explicit associations.
- Preserve explicit app-launch metadata when a shell changes its working directory.
- Use pane directories/process hints for externally launched agents; show uncertain matches
  and permit manual association rather than labeling every shell an agent.
- Distinguish process liveness from “working”, “awaiting approval”, or “finished”. Rich status
  needs provider evidence; unsupported status is unknown.
- Non-tmux processes cannot generally be adopted safely. Saved conversations are not live
  terminals; provider-specific discovery/resume is a separate future feature.

**Acceptance:** all matching live tmux agents across sessions appear in a project group;
ambiguous matches are visible/editable; matching is unit-tested for nested roots, worktrees,
symlinks, renamed/missing folders, shell cwd changes, and escaped/unusual paths.

## Gate 3: native workspace UI

Add project registration, metadata editing, sidebar selection, overview, and terminal tabs.
Provide clear missing-tmux, disconnected, empty-project, and permission-denied states.
Keep app window groups distinct from macOS windows and native tmux session groups in labels.

**Acceptance:** keyboard navigation and accessibility work; switching groups preserves terminal
state; iOS chat is unchanged. Include compact macOS/iOS screenshots in the PR.

## Gate 4: launch and restore

Add launch profiles with executable + argument arrays and explicit project cwd. Pass paths
as arguments rather than interpolating untrusted text into a shell. Custom shell commands
are explicitly user-authored actions and must never auto-run because a folder was opened.
Persist group membership and layouts, not terminal process ownership or transcript secrets.

**Acceptance:** reopening attaches to live targets without duplicate agents; launching missing
agents is explicit; server restarts and exited agents recover predictably; termination is
confirmed; tests cover missing executables, failures, spaces, quotes, and concurrent opens.

## Review and completion checklist

- [x] Promote the app and preserve bundle/keychain identities.
- [x] Build macOS/iOS; run core, app-package, and iOS identity/UI smoke tests.
- [ ] Resolve local macOS hosted-test launch timeouts and verify signed credential access.
- [ ] Complete sandbox/independent-terminal spike and record the decision.
- [ ] Implement/test project matching and live tmux discovery.
- [ ] Implement workspace UI without disrupting existing chat.
- [ ] Implement explicit launching and non-destructive restoration.
- [ ] Run reviewer + security review, integration tests on a disposable tmux server,
      and capture visual evidence before merging each implementation slice.

Phase 1's delegated review was blocked by the Claude subscription session limit;
independent review remains required. No tmux implementation should start until Gate 1
has a tested, approved approach.
