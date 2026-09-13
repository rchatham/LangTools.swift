# LangToolsCLI Codex Helper

The sandboxed example app delegates Codex Subscription authentication and chat to this external helper. The helper uses the installed official Codex CLI through `codex app-server`; it does not receive or persist OpenAI browser OAuth tokens.

## Start the helper

```bash
cd cli
TOKEN="$(openssl rand -hex 32)"
echo "Helper token: $TOKEN"
swift run LangToolsCLI serve --host 127.0.0.1 --port 8765 --token "$TOKEN"
```

Configure `http://127.0.0.1:8765` and the printed token under **Settings → Model Access → Codex Subscription**. The helper token authenticates local app-to-helper requests and is unrelated to the Codex account session.

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

## Verification

```bash
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/health
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/auth/status
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/models/codex
```
