# Pi + Ollama Cloud CI migration plan

## Scope

Migrate the repository's mention-driven coding assistant and automatic pull-request review workflows from Claude Code to the Pi coding agent using Ollama Cloud GLM-5.2. Add a separately gated live smoke test for the Swift Ollama client without changing deterministic provider/fixture tests.

## Identifiers and endpoints

- Pi provider/model: `ollama-cloud/glm-5.2`, via the OpenAI-compatible endpoint `https://ollama.com/v1`.
- Swift live integration model: `glm-5.2`, via the native Ollama endpoint host `https://ollama.com` (`/api/chat`).
- Authentication: `Authorization: Bearer $OLLAMA_API_KEY`.

Both direct Cloud APIs advertise the untagged `glm-5.2`. The `glm-5.2:cloud` tag is for local Ollama routing. The timed-out worker's tagged Pi ID was corrected after checking the public native and OpenAI-compatible Cloud catalogs.

## Changes

1. Commit a CI-only Pi `models.json` with environment-based authentication and explicit Ollama compatibility flags.
2. Replace the Claude mention workflow with a trusted-collaborator-only `@pi` responder. Run Pi headlessly without tools, check out only the trusted default branch, pass event content through files/stdin, and let the workflow—not the model—post the response.
3. Replace automatic Claude review with a same-repository-PR-only Pi review using the trusted `pull_request_target` workflow against main. Fetch the PR diff as data, never check out/execute PR code, run Pi without tools or repository context files, and upsert a marker-owned `github-actions[bot]` review comment.
4. Add optional bearer authentication to the Swift Ollama client and unit-test the generated header.
5. Add an opt-in live Cloud chat smoke test. Keep it skipped by default, require explicit enablement and a key, and run it only on trusted `main` pushes (`RUN_OLLAMA_CLOUD_TESTS=true`) or main manual dispatch (`run_ollama_cloud_tests=true`). Set bounded network timeouts.
6. Restrict mention triggers to default-branch `issue_comment` and `issues` events, and verify the sender's current write/maintain/admin permission before inference. Inline review events are intentionally excluded because their workflow definition can originate from a PR. Scope the Ollama secret to inference/live-test steps and blank GH_TOKEN during inference.

## Security constraints

- Never expose `OLLAMA_API_KEY` to fork pull-request workflows or untrusted checked-out code.
- Do not grant Pi shell, edit, write, commit, or push tools in GitHub Actions.
- Use least-privilege `GITHUB_TOKEN` permissions; no `id-token: write` or `contents: write`.
- Do not interpolate issue, comment, title, or diff text into shell source. Read event JSON and pipe data through files/stdin.
- Pin the Pi npm package version and disable npm lifecycle scripts.

## Verification completed (2026-09-13)

- Baseline `swift test` on inherited changes: 262 tests, 1 intentional live-test skip, 0 failures.
- Final `swift test`: 263 tests, 1 intentional live-test skip, 0 failures. Existing fixture tests and model semantics unchanged.
- `swift test --filter OllamaCloudIntegrationTests`: 1 test skipped, 0 failures without opt-in.
- `env -u OLLAMA_API_KEY LANGTOOLS_RUN_OLLAMA_CLOUD_TESTS=1 swift test --filter OllamaCloudIntegrationTests`: expected exit 1 with explicit missing-key failure.
- `/tmp/pi-ci-validation/bin/actionlint .github/workflows/pi-coding.yml .github/workflows/pi-review.yml .github/workflows/swift.yml`: passed (actionlint v1.7.7 installed in temporary directory).
- Ruby YAML/JSON parsing for all workflow/Pi config files and `bash -n` on every workflow run block: passed.
- `git diff --check`: passed.
- `npm pack @earendil-works/pi-coding-agent@0.85.1 --ignore-scripts --pack-destination /tmp/pi-ci-validation`: downloaded successfully; SHA-256 matches both workflows (`1f498729649bdce647d1160993b4d92bf3c614cc819213bee2f91dd34f2a7af4`). Temporary install with `--ignore-scripts` succeeds; pinned CLI reports 0.85.1.
- Pinned Pi `--list-models glm-5.2` with isolated committed config, disabled discovery/trust and placeholder key: resolves `ollama-cloud/glm-5.2`, 1M context, 16.4K output, text-only.
- Primary sources fetched directly: https://ollama.com/api/tags and https://ollama.com/v1/models both list `glm-5.2`; https://ollama.com/library/glm-5.2 documents local `:cloud` routing and 976K context; https://docs.ollama.com/cloud documents native host/Bearer auth. https://docs.ollama.com/api/openai-compatibility checked for API compatibility.
- Read installed Pi `models.md`, `providers.md`, `environment-variables.md`, `usage.md`, `security.md`, and linked `containerization.md` in full. Confirmed environment interpolation, model IDs passed through to API, isolation flags, stdin print mode, and trust-not-a-sandbox semantics.

## Explicit blockers / handoff

- No real `OLLAMA_API_KEY` was available. No successful live generation or GitHub Actions run is claimed. A temporary fetch-mocking attempt did not intercept the pinned CLI transport and received HTTP 401 using a deliberately fake key; this is not a successful transport/inference test.
- `shellcheck` is not installed; actionlint plus `bash -n` passed, but ShellCheck-specific checks remain outstanding.
- Parent will arrange independent code/security reviews and post-merge or trusted-branch CI validation. Nothing committed, pushed, or published.
- Coding is intentionally comment-only guidance/unified-diff proposals, not autonomous edits, branch creation, or push. Inline review mentions are unsupported; use a top-level PR conversation comment with `@pi`.
- Prompt injection can affect advice even without tools; generated comments are untrusted, never approvals. Large diffs are truncated with an explicit warning.
- Repository setup requires Actions secret `OLLAMA_API_KEY`; automatic comments use the built-in `GITHUB_TOKEN`. Live tests additionally require the opt-in variable/input described above; `OLLAMA_CLOUD_MODEL` optionally overrides only the Swift smoke-test model. No Claude secret is needed by the replacement workflows.
- Git pull/rebase was intentionally not performed: this task resumes an explicitly isolated dirty worktree and must not alter parent/PR32 state.
