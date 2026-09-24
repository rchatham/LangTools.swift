# LangToolsCLI Codex Helper

The sandboxed example app delegates Codex Subscription authentication and chat to this external helper. The helper uses the installed official Codex CLI through `codex app-server`; it does not receive or persist OpenAI browser OAuth tokens.

## Start the helper

From the **LangTools.swift repository root**, run:

```bash
make codex-helper
```

The target creates a private token at `~/.langtools/helper-token` on first use and reuses it on subsequent runs (the same token file as the menu-bar app). Copy its contents into **Settings → Model Access → Codex Subscription** alongside the URL `http://127.0.0.1:8765`. To see the token when needed, run `cat ~/.langtools/helper-token` in a private terminal (do not share or commit it). Override the defaults with `make codex-helper CODEX_HELPER_PORT=8766 CODEX_HELPER_TOKEN_FILE=/absolute/private/path` if needed.

The helper token authorizes local app-to-helper requests and is unrelated to the Codex account session. It must be supplied through a mode-0600, user-owned file so it never appears in `ps`/argv or shell history. The equivalent manual command is:

```bash
cd cli
TOKEN="$(openssl rand -hex 32)"
TOKEN_FILE="$(mktemp -t langtools-helper-token)"
(umask 077; printf '%s' "$TOKEN" > "$TOKEN_FILE")
# Display the token once to copy into Settings; it is not printed again.
printf 'Helper token: %s\n' "$TOKEN"
swift run LangToolsCLI serve --host 127.0.0.1 --port 8765 --token-file "$TOKEN_FILE"
```

`--token` (argv) is rejected; use `--token-file`. Configure `http://127.0.0.1:8765` and the token under **Settings → Model Access → Codex Subscription**. Numeric loopback hosts (`127.0.0.1` or `::1`) are required; `localhost` is not accepted.

Codex state is resolved in this order:

1. `LANGTOOLS_CODEX_HOME`
2. `CODEX_HOME`
3. `$HOME/.codex`

`LANGTOOLS_CODEX_PATH` may point to a specific `codex` executable.

## Menu-bar helper app

**Development build only:** `make helper-app` ad-hoc signs the bundle; it is not notarized or ready for public downloads. Pairing currently passes the long-lived bearer token through a custom URL scheme, which another installed app could claim. Before distribution, replace this with trusted app-to-helper IPC/pairing and Developer ID signing/notarization. The token file is private from other users and browser tabs, but not from processes running as the same user.

Instead of the terminal command, build and launch the menu-bar app in one step:

```bash
make helper-app-open
```

For a standalone bundle to double-click later, run `make helper-app`; the app is written to `build/LangTools Helper.app`.

The app lives in the menu bar (no Dock icon). On launch it ensures the shared token file at `~/.langtools/helper-token` — generating a fresh 64-hex token with `SecRandomCopyBytes` on first use, written mode 0600 with no trailing newline — and starts the server automatically on `http://127.0.0.1:8765`. An existing token file is validated with the same security rules as the CLI (`HelperTokenLoader`: regular file, owned by you, no group/other permissions, single line) and reused.

The menu offers:

- a status line (`Running at http://127.0.0.1:8765` / `Stopped`),
- **Start/Stop Helper** (stopping cancels the server cleanly, so it can be restarted),
- **Pair with LangTools Example…** (enabled while running),
- **Copy Token** and **Quit**.

### One-click pairing

**Pair with LangTools Example…** opens the already-registered custom URL scheme:

```
langtools-example-auth://codex-helper/pair?port=8765&token=<64 hex chars>
```

LangTools_Example shows a confirmation alert before saving anything; on confirm it stores the helper token and base URL (`http://127.0.0.1:8765`) and verifies them with a `/health` check, then **Settings → Model Access → Codex Subscription** shows the paired status. Manual URL/token entry remains available as a fallback. The helper server only accepts requests whose `Host` header resolves to `127.0.0.1`, `::1`, or `localhost` — anything else is rejected with `400 Unexpected Host header.`

## Authentication

Choose **Sign in to Codex** in the app. The helper asks `codex app-server` to start the official ChatGPT browser flow and adopts an existing authenticated Codex session when available. Codex owns PKCE, callback handling, credential storage, and token refresh.

If the installed Codex version does not support app-server login, update Codex or authenticate externally with the same resolved home:

```bash
CODEX_HOME="$HOME/.codex" codex login
```

Then retry **Sign in to Codex**. Never pass browser OAuth access or ID tokens to `codex login --with-access-token`; that option accepts different Codex token formats.

## Codex capability boundary

The helper does not forward app-provided tools, legacy `tools`/`toolChoice` fields, or helper-defined dynamic tools to Codex. It starts turns with Codex's supported workspace-write sandbox policy and `networkAccess: false`; that setting constrains network access for commands executed inside the local sandbox only. It is **not** total network isolation: the user's native Codex account configuration can still include hosted capabilities or MCP servers managed by Codex.

On macOS the helper launches `codex app-server` (and every command it spawns) under an OS-level seatbelt (`sandbox-exec`) profile that is deny-by-default for file access. Reads are allowed only for system runtime paths, the resolved Codex home, the helper-owned conversation workspace, and process temporary directories; reads of the user's home tree (`~/.ssh`, `~/Documents`, …) and any other path are denied by the kernel. Codex-native tools keep working (process exec/fork and network remain allowed, and spawned commands inherit the same seatbelt), while persistent per-conversation workspace state stays readable and writable.

## Verification

```bash
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/health
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/auth/status
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/models/codex
```
