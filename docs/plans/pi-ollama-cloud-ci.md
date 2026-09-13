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

## Verification

- `swift test`: 294 tests, 1 intentional live-test skip, 0 failures.
- `swift test --filter OllamaCloudIntegrationTests`: 3 tests, 1 skipped without explicit opt-in, 0 failures.
- `ruby .github/pi/tests/prompt_test.rb`: 6 tests, 61 assertions, 0 failures. These fixture-based prompt, trust-boundary, and posting checks require no credentials or network and also run in pull-request and main CI.
- Actionlint, workflow YAML parsing, Pi JSON parsing, shell syntax validation, and `git diff --check` pass.
- The pinned Pi package tarball checksum matches `1f498729649bdce647d1160993b4d92bf3c614cc819213bee2f91dd34f2a7af4`. Its exact runtime dependencies are installed with `npm ci --ignore-scripts` from the committed integrity-bearing lockfile before the verified top-level package is extracted. The isolated model configuration resolves `ollama-cloud/glm-5.2`.
- Independent code and security reviews found no unresolved code-level security issues. Review follow-ups added source-compatible authenticated initializers, explicit context truncation warnings, bounded GitHub comments, regression coverage, and locked Pi dependency installation.

## Deployment and smoke tests

The repository Actions secret `OLLAMA_API_KEY` is configured. An authenticated request using the exact pinned Pi package and committed provider configuration reached Ollama Cloud, but the account returned HTTP 429 because its session usage limit was exhausted. No successful generation is claimed until account capacity is restored.

After the secret is configured and the change is present on `main`:

1. Dispatch the Swift workflow on `main` with `run_pi_cloud_test=true`. The pinned Pi CLI must return a non-empty GLM-5.2 response through the committed OpenAI-compatible provider configuration.
2. Dispatch with `run_ollama_cloud_tests=true`. `OllamaCloudIntegrationTests` must complete a native `/api/chat` request and return non-empty content.
3. Add `@pi` to a top-level issue or pull-request conversation comment from an account with repository write access. Confirm the assistant posts a visibly labeled response.
4. Open or synchronize a same-repository pull request. Confirm the review workflow creates or updates its marker-owned comment.

Fork pull requests remain intentionally excluded from secret-bearing automation. Generated comments are untrusted advice, never approvals. The optional Swift bearer-auth API permits caller-selected endpoints; callers are responsible for selecting trusted HTTPS hosts, while the live integration test requires HTTPS.
