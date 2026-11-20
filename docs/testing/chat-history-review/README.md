# ChatHistory review screenshots (2026-11-19)

iOS Simulator, iPhone 17 Pro, iOS 26.3.1. The stores hold the conversations Botsworth imported from its committed legacy fixture (`LegacyChatStoreV1`), so both apps show the same records.

- `launch-new-chat-light.png`, `launch-new-chat-dark.png`: on iPhone the LangTools app opens on a new chat, with History at the top left.
- `history-sheet-light.png`, `history-sheet-dark.png`: History opens as a sheet over the chat (`ChatHistoryListView`, `.stack` style). "Botsworth" is that bot's main thread; the demo app lists every conversation (`ConversationQuery.all`).
- `opened-from-history-light.png`: picking a conversation closes the sheet and opens it, with its agent row and card fallback restored.
- `conversation-light.png`: the same conversation from the earlier layout, where the app opened on the list.
- `settings-history-single-form.png`: `ChatHistorySettingsView` in this branch's single-form iOS settings, where each custom tab is a `Section`.
- `settings-history-submenu-light.png`, `settings-history-submenu-dark.png`: the same view in the iOS settings submenus from `feature/botsworth-helper-launch`, captured in Botsworth.
- `settings-history-before-fix.png`: before `5e54df9`. The view nested its own `Form` in the host's `Form` and collapsed to a clipped header.

Not captured: macOS.
