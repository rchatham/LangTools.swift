# Coding workspace implementation

Branch: `feature/coding-agent-workspace`. Status: **in progress; not usable yet**.

## Approved scope

User-approved local-helper-backed, user-directed coding agents: projects with
folders/notes/groups, project overview, explicit parallel launches and task
assignment, reconnectable interactive terminals, and separately confirmed stop.
Keep existing chat, app sandbox/identities, and iOS compatibility. No autonomous
pipelines, remote execution, or mobile-relay coding capability in this MVP.

## Architecture and security boundaries

- Helper-local consent enables a separate ephemeral random workspace credential;
  chat pairing/token possession alone never grants coding access. Enabling again
  rotates the credential and clears roots. Disabling revokes grants.
- Approve roots in helper UI, not via a network request. Canonicalize existing
  directories with `realpath`, match path components, revalidate per operation.
- **Roots constrain selected launch directories, not executable filesystem
  access.** Arbitrary agents execute with the helper user's privileges and may
  access other files/network. Local consent must disclose this; this is not a
  new containment sandbox. Path checks cannot eliminate concurrent filesystem
  replacement races. Do not represent them as such.
- Coding routes must require both local server authentication and the separate
  workspace credential. Never add coding routes to mobile relay or weaken
  `HelperChatRequest` validation. Reject browser-origin coding requests.
- A helper-owned tmux service will use explicit argument arrays and a private
  server/socket for app-launched agents. Existing-session attachment must be
  non-destructive and independently selectable before expanding discovery.
- Interactive terminal transport must carry actual PTY bytes/input/resize with
  bounded buffers and cancellation. Captured text is not a terminal substitute.
  Disconnect removes only the viewer; explicit stop targets only its agent.
- Stable server/session/window/pane identities and explicit project associations
  survive cwd changes. No fabricated working/approval/completion states.
- App-only terminal dependencies, macOS-conditional presentation, existing iOS
  chat unchanged. Projects/groups are app metadata, not tmux session groups.

## Milestones

- [x] Create repository-local worktree and confirm helper boundary approval.
- [x] Implement separately revocable access policy and path/credential tests.
- [ ] Wire helper consent/roots and separately authenticated coding routes.
- [ ] Implement tmux lifecycle and prove independent PTY attachment on a disposable socket.
- [ ] Implement bounded terminal transport; input, resize, Unicode, reconnect tests.
- [ ] Add project persistence, sidebar/overview/launch/terminal/stop presentation.
- [ ] Run core/app/helper suites, macOS/iOS builds, UI verification and screenshots.
- [ ] Independent general/security review, draft PR updates, final verification.

## Verification log

2026-10-27:
- Initial full `swift test --package-path cli` built but exceeded 600 seconds
  during existing Codex app-server tests. Log:
  `/tmp/langtools-workspace-cli-baseline.log`. Terminated the orphaned task-owned
  XCTest process (PID 70713); full baseline is **not passing verification**.
- Focused access tests initially caught a test expectation using `/var` rather
  than canonical `/private/var`; corrected expectation to the approved root.
- Ran `swift test --package-path cli --filter 'CodingWorkspaceAccessTests|LocalHelperServerTests'`
  successfully. See `/tmp/langtools-workspace-access-tests.log`.
- No UI/runtime integration or screenshots yet. No real agents launched.
- Delegation unavailable: provider auth/quota cooldowns; OpenRouter attempt
  returned insufficient credits. Independent review remains outstanding; first
  slice inspected in parent session only.

## Next step

Implement the helper-owned tmux/PTY service with injectable test configuration;
prove argument safety, independent attachment, detachment, explicit stop, and
server-restart identity handling using a disposable tmux socket before UI work.
The policy is currently a tested building block, not exposed over any endpoint.
