# History and context review — 2026-11-10

Scope: LangTools PR #92 (`feature/chat-history`) and stacked #94 (`feature/chat-context`). No merge authorized or performed. Trello mapping unavailable; no board update made.

## #92

- CI now covers pull requests to all bases and selects ChatContextTests when present, preserving main-only paid smoke guards.
- Retention defaults to forever. Opt-in deletion uses the latest createdAt, updatedAt, lastMessageAt or archivedAt, strictly before the cutoff. Pinned, exempt and live sessions remain protected.
- Failed retention preview no longer enables deletion without confirmation. Exports now propagate flush failures and read metadata after flushing.
- Focused macOS Swift tests: 25 Chat tests and 84 ChatHistory tests (11 abstract-base skips), zero failures. Includes real expiry, protected chats, boundary dates, metadata activity, closed-session sends and failed-export recovery. Workflow YAML/selection checks and git diff --check passed.
- Remaining: hosted CI at published revision; native app/UI acceptance; current main reconciled, preserving the keyboard-isolation pin; retarget #92 to main after publishing. Native build is blocked on Xcode approval for the pinned JSONMacroPlugin.

## #94

- Inherits #92 fixes. Reopening without a preparer now loads the full transcript.
- Deleting a covered message or child invalidates affected summaries instead of moving their boundary and retaining deleted content. Surviving earlier summaries remain usable.
- Process-local transcript revisions discard transient fallback summaries and cancel summaries racing with deletion. Sessions flush deletions and restore hidden history before the next request.
- Focused macOS tests: 25 Chat tests, 126 ChatHistory tests (19 abstract-base skips), 63 ChatContext tests; zero failures.
- Checkpoint read failures now block requests rather than silently omitting summarized history.
- Remaining: hosted CI and native app/UI checks. Native build stopped at Xcode approval for the pinned JSONMacroPlugin; no validation bypass was used. No live-provider overflow request was made.
