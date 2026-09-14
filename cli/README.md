# LangToolsCLI Codex Helper

The sandboxed example app delegates Codex Subscription authentication and chat to this external helper. The helper uses the installed official Codex CLI through `codex app-server`; it does not receive or persist OpenAI browser OAuth tokens.

## Start the helper

The helper token authorizes local app-to-helper requests and is unrelated to the Codex account session. It must be supplied through a mode-0600, user-owned file so it never appears in `ps`/argv or shell history.

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
