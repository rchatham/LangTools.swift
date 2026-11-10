# History and context review — 2026-11-10

Scope: LangTools PR #92 (`feature/chat-history`) and stacked #94 (`feature/chat-context`). No merge authorized or performed. Trello mapping unavailable; no board update made.

## #92

- CI now covers pull requests to all bases and selects ChatContextTests when present, preserving main-only paid smoke guards.
- Retention defaults to forever. Opt-in deletion uses the latest createdAt, updatedAt, lastMessageAt or archivedAt, strictly before the cutoff. Pinned, exempt and live sessions remain protected.
- Failed retention preview no longer enables deletion without confirmation. Exports now propagate flush failures and read metadata after flushing.
- Focused macOS Swift tests: 14 Chat tests and 82 ChatHistory tests (11 abstract-base skips), zero failures. Includes real expiry, protected chats, boundary dates and failed-export recovery. Workflow YAML/selection checks and git diff --check passed.
- Remaining: hosted CI at published revision; native app/UI acceptance; base branch is not yet an ancestor of main, so retain the stack rather than retarget blindly.

## #94

- Inherits #92 fixes. Reopening without a preparer now loads the full transcript.
- Deleting a covered message or child invalidates affected summaries instead of moving their boundary and retaining deleted content. Surviving earlier summaries remain usable.
- Process-local transcript revisions discard transient fallback summaries and cancel summaries racing with deletion. Sessions flush deletions and restore hidden history before the next request.
- Focused macOS tests: 14 Chat tests, 124 ChatHistory tests (19 abstract-base skips), 62 ChatContext tests; zero failures.
- Remaining: hosted CI and native app/UI checks. No live-provider overflow request was made.
