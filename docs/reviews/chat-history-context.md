# History and context review — 2026-11-10

Scope: LangTools PR #92 (`feature/chat-history`) and stacked #94 (`feature/chat-context`). No merge authorized or performed. Trello mapping unavailable; no board update made.

## #92

- CI now covers pull requests to all bases and selects ChatContextTests when present, preserving main-only paid smoke guards.
- Retention defaults to forever. Opt-in deletion uses the latest createdAt, updatedAt, lastMessageAt or archivedAt, strictly before the cutoff. Pinned, exempt and live sessions remain protected.
- Failed retention preview no longer enables deletion without confirmation. Exports now propagate flush failures and read metadata after flushing.
- Focused macOS Swift tests: 14 Chat tests and 82 ChatHistory tests (11 abstract-base skips), zero failures. Includes real expiry, protected chats, boundary dates and failed-export recovery. Workflow YAML/selection checks and git diff --check passed.
- Remaining: hosted CI at published revision; native app/UI acceptance; base branch is not yet an ancestor of main, so retain the stack rather than retarget blindly.

## #94

Review in progress: checkpoint/deletion consistency and paging without a request preparer; focused context/storage/session tests next.
