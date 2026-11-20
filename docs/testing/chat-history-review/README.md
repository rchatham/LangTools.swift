# ChatHistory review screenshots (2026-11-19)

iOS Simulator, iPhone 17 Pro, iOS 26.3.1. The stores hold the conversations Botsworth imported from its committed legacy fixture (`LegacyChatStoreV1`), so both apps show the same records.

- `history-list-light.png`, `history-list-dark.png`: the LangTools app's `ChatHistoryListView`. "Botsworth" is that bot's main thread; the demo app lists every conversation (`ConversationQuery.all`).
- `conversation-light.png`: a stored conversation opened from the list, with its agent row and card fallback restored.
- `settings-history-single-form.png`: `ChatHistorySettingsView` in this branch's single-form iOS settings, where each custom tab is a `Section`.
- `settings-history-submenu-light.png`, `settings-history-submenu-dark.png`: the same view in the iOS settings submenus from `feature/botsworth-helper-launch`, captured in Botsworth.
- `settings-history-before-fix.png`: before `5e54df9`. The view nested its own `Form` in the host's `Form` and collapsed to a clipped header.

Not captured: macOS.
