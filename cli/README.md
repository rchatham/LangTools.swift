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
swift run langtools serve --host 127.0.0.1 --port 8765 --token-file "$TOKEN_FILE"
```

`--token` (argv) is rejected; use `--token-file`. Configure `http://127.0.0.1:8765` and the token under **Settings → Model Access → Codex Subscription**. Numeric loopback hosts (`127.0.0.1` or `::1`) are required; `localhost` is not accepted.

Codex state is resolved in this order:

1. `LANGTOOLS_CODEX_HOME`
2. `CODEX_HOME`
3. `$HOME/.codex`

`LANGTOOLS_CODEX_PATH` may point to a specific `codex` executable.

## Menu-bar helper app

**Development build only:** `make helper-app` ad-hoc signs the bundle; it is not notarized or ready for public downloads. Pairing uses a short-lived single-use 64-hex code that is exchanged for the bearer token over an authenticated loopback POST (code TTL: 5 minutes, single use; no token in URL). Another installed app could still claim the custom URL scheme and intercept the code, though without the matching loopback the exchange would fail. Before distribution, replace this with trusted app-to-helper IPC/pairing and Developer ID signing/notarization. The token file is private from other users and browser tabs, but not from processes running as the same user.

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
- **Connect iPhone…** (separate opt-in encrypted LAN relay; Ollama by default, optional Codex/Claude Code account capabilities),
- **Copy Token** and **Quit**.

### One-click pairing

**Pair with LangTools Example…** opens the already-registered custom URL scheme:

```
langtools-example-auth://codex-helper/pair?port=8765&code=<64 hex chars>
```

LangTools_Example shows a confirmation alert before saving anything; on confirm it exchanges the single-use code for the bearer token over a loopback `POST /v1/pairing/exchange`, stores the token, and verifies the helper with a `/health` check. Then **Settings → Model Access → Codex Subscription** shows the paired status. Manual URL/token entry remains available as a fallback. The helper server only accepts requests whose `Host` header resolves to `127.0.0.1`, `::1`, or `localhost` — anything else is rejected with `400 Unexpected Host header.`

### iPhone Ollama pairing (opt-in LAN)

Choose **Connect iPhone…**, select an active private IPv4 interface, then explicitly enable **Allow encrypted iPhone access on this network**. The separate TLS listener binds only that selected address on port8086. By default it grants only Ollama access. Optional account capabilities require explicit opt-in; desktop credentials and login/logout/administration routes are never exposed. LAN access is off at every helper launch; stopping the desktop loopback listener does not change the independently controlled LAN toggle.

Scan the five-minute single-use QR with iPhone Camera and confirm the named Mac and listed capabilities in LangTools. Ollama-only links retain the v1 contract; v2 links explicitly bind optional account grants to the confirmation. Pairing does not select account transports: choose them separately in **Settings → Model Access**. Refresh invalidates the previous QR; cancel/close/expiry invalidates pairing without revoking existing devices. **Revoke** removes a device and interrupts its in-flight requests. Disable LAN or quit the helper to stop all phone traffic. Interface disappearance/address changes stop LAN rather than silently switching interfaces. Direct Ollama remains an explicit app alternative, never a failover from helper TLS.

The helper creates a persistent self-signed identity using `/usr/bin/openssl` in a mode0700 temporary directory with mode0600 files, imports via Security, and stores private material only in the macOS login Keychain (`com.langtools.helper.mobile-identity.v1`). Phones trust only the exact QR-pinned SHA256 leaf plus a valid anchored basic X.509 evaluation: trust follows helper identity, not a changing numeric IP. Never approve arbitrary certificates or substitute plaintext. Device metadata/token hashes persist atomically in mode0600 `~/.langtools/mobile/devices-v1.json`; reusable tokens and active QR codes are not stored there.

The mobile HTTP allowlist is `POST /v1/mobile/pair`, authenticated `GET /v1/mobile/health`, `GET /v1/ollama/api/{version,tags,ps}`, and `POST /v1/ollama/api/{chat,generate,pull}`. Only the fixed upstream `http://127.0.0.1:11434` is contacted, with no forwarded mobile Authorization or redirects. Bounds:8 concurrent connections,32KiB request headers,4MiB request bodies,1MiB NDJSON lines,16MiB non-NDJSON/256MiB streamed response total,10s request-read/15s downstream-send/300s total route deadlines. Responses stream incrementally; disconnect/revocation cancels the local upstream. A failed response after headers closes the stream without a fabricated completion event (Foundation can surface this as EOF; clients require final `done: true` for chat/generate and final `status: "success"` for model pulls).

#### Optional account capabilities

Before enabling LAN, opt in to **Allow Codex account chat and models** and/or **Allow external Claude Code backend relay**. Both are off by default. Scope/backend changes stop LAN and invalidate the QR; existing devices never gain new grants automatically. Re-pair to add a capability.

- **Codex:** sign in on the Mac using the existing Codex helper. The phone uses its scoped device token, not an OAuth token. Allowed LAN routes are model discovery, read-only account status, chat completions and device-owned conversation cleanup. **Codex retains the Mac runtime's native tool permissions, including filesystem and command execution within the existing runtime policy; this is not per-device filesystem isolation. Enable only for trusted phones.**
- **Claude Code:** configure an existing external backend with an explicit numeric-loopback HTTP origin and port (no path/query). This is not a new native Claude subscription runtime. The phone still needs that backend's account session. `/v1/claude/models` and `/v1/claude/chat/completions` relay only to the configured backend's `/auth/claude-code/models` and `/account/chat/completions`. The separate account token becomes upstream authorization; the device token and desktop token are not forwarded. Login/logout stay local, redirects are rejected, and there is no fallback.
- **App routing:** each account provider can explicitly select its existing backend or the paired helper. Platform models continue to use **Direct API key**. Model/settings labels identify the actual selected route. Missing grants, revocation, trust changes or helper failure fail closed; captured in-flight requests retain their original route.

The original Ollama allowlist and bounds above remain unchanged. Optional providers use the same TLS/device authorization, enabled-and-granted capability checks, deadlines and response bounds. Revoke/disable cancels active work; Codex cleanup joins producer interruption before freeing its slot.

See [LAN account setup and current verification](../docs/helper-lan-providers.md) for screenshots, exact test commands and remaining iOS/physical-device blockers. This feature does **not** proxy OpenAI/Anthropic/Gemini/xAI API-key traffic.

For UI verification without automatically enabling LAN:

```bash
cd cli
swift build --product LangToolsHelper
.build/debug/LangToolsHelper --connect-iphone
```

Capture LAN-off, QR-cancelled/expired, and paired-device/revocation states. **Never share an active QR or its URL**: capture only after cancel/expiry, or redact the full QR region before sharing and discard the unredacted image. Physically scanning the QR and iPhone LAN/TLS/relaunch behavior still require real-device acceptance; a Mac integration test is not a substitute.

## Authentication

Choose **Sign in to Codex** in the app. The helper asks `codex app-server` to start the official ChatGPT browser flow and adopts an existing authenticated Codex session when available. Codex owns PKCE, callback handling, credential storage, and token refresh.

If the installed Codex version does not support app-server login, update Codex or authenticate externally with the same resolved home:

```bash
CODEX_HOME="$HOME/.codex" codex login
```

Then retry **Sign in to Codex**. Never pass browser OAuth access or ID tokens to `codex login --with-access-token`; that option accepts different Codex token formats.

## Codex capability boundary

The helper does not forward app-provided tools, legacy `tools`/`toolChoice` fields, or helper-defined dynamic tools to Codex. It starts turns with Codex's supported workspace-write sandbox policy and `networkAccess: false`; that setting constrains network access for commands executed inside the local sandbox only. It is **not** total network isolation: the user's native Codex account configuration can still include hosted capabilities or MCP servers managed by Codex.

On macOS both `codex app-server` and the one-shot `openai-chat` bridge launch Codex (and every command it spawns) under an OS-level seatbelt (`sandbox-exec`) profile that is deny-by-default for file access. Reads are allowed only for system runtime paths, the resolved Codex home, the helper-owned conversation workspace, and one owner-only temporary directory dedicated to that Codex process. Broad `/private/var`, `/tmp`, `/private/tmp`, and `/private/var/folders` grants are not used. Each child receives an allowlisted environment with `TMPDIR`, `TMP`, and `TEMP` redirected to its private directory; API keys, proxy credentials, agent sockets, and unrelated parent configuration are not inherited.

Codex launches fail closed if `sandbox-exec` or the required workspace is unavailable. Codex-native tools keep working (process exec/fork and network remain allowed, and spawned commands inherit the same seatbelt), while persistent per-conversation workspace state stays readable and writable. The example bridge also stages each chat request in a dedicated mode-0700 directory with a mode-0600 JSON file and removes the directory after the command completes.

## Verification

```bash
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/health
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/auth/status
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/models/codex
```
