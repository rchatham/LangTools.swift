# History and context review — 2026-11-10

Scope: LangTools PR #92 (`feature/chat-history`) and stacked #94 (`feature/chat-context`). No merge authorized or performed. Trello mapping unavailable; no board update made.

## #92

- CI now covers pull requests to all bases and selects ChatContextTests when present, preserving main-only paid smoke guards.
- Retention defaults to forever. Opt-in deletion uses the latest createdAt, updatedAt, lastMessageAt or archivedAt, strictly before the cutoff. Pinned, exempt and live sessions remain protected.
- Failed retention preview no longer enables deletion without confirmation. Exports now propagate flush failures and read metadata after flushing.
- Focused macOS Swift tests: 22 Chat tests and 84 ChatHistory tests (11 abstract-base skips), zero failures. Includes real expiry, protected chats, boundary dates, metadata activity, closed-session sends and failed-export recovery. Workflow YAML/selection checks and git diff --check passed.
- Remaining: hosted CI at published revision; native app/UI acceptance; current main reconciled, preserving the keyboard-isolation pin; retarget #92 to main after publishing.

## #94

Review in progress: checkpoint/deletion consistency and paging without a request preparer; focused context/storage/session tests next.
