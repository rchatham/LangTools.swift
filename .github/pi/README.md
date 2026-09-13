# Pi CI configuration

The Pi coding and review workflows use the custom provider in `models.json`:

- Provider/model: `ollama-cloud/glm-5.2`
- Endpoint: Ollama's OpenAI-compatible `https://ollama.com/v1`
- Authentication: repository Actions secret `OLLAMA_API_KEY`

Both direct Cloud APIs advertise `glm-5.2`; `glm-5.2:cloud` is the local Ollama CLI routing tag, not the ID used here. Verified against `https://ollama.com/v1/models` and `https://ollama.com/api/tags`.

The Swift live smoke test uses Ollama's native API at `https://ollama.com/api/*` with model ID `glm-5.2`. The optional repository variable `OLLAMA_CLOUD_MODEL` can override that integration-test model without changing source. `OLLAMA_CLOUD_BASE_URL` is supported by the test for local invocation but is intentionally not set in CI.

Live tests are off by default. Enable `RUN_OLLAMA_CLOUD_TESTS=true` as a repository variable for main pushes, or select `run_ollama_cloud_tests` in a manual dispatch on main. A selected run fails if its secret is missing. Locally, set `LANGTOOLS_RUN_OLLAMA_CLOUD_TESTS=1` and `OLLAMA_API_KEY`, then run `swift test --filter OllamaCloudIntegrationTests`.

The workflows run only trusted same-repository or write-access-collaborator-requested work with the secret. Automatic reviews use `pull_request_target` against main, never execute PR code, and ignore fork PRs. Mention requests use default-branch `issue_comment`/`issues` events. Use `@pi` in a top-level PR conversation comment: inline review comments/reviews are deliberately not triggers because their workflow definitions can originate from PR code. Pi receives no tools, cannot change or push repository contents, and the workflow checks out only the trusted default branch. Fork pull requests continue to run deterministic Swift tests but do not receive an automated model review or the live Cloud smoke test.

The coding assistant proposes guidance or patches in comments; it does not autonomously apply patches. Both assistants treat model output as untrusted advice, not approvals or executable code. Prompt injection can still corrupt that advice. Large diffs are explicitly marked as partial context. Pi's API key is scoped to the inference step; the GitHub token is blanked there. The blank `auth.json` intentionally contains no credentials.

Run the fixture-based workflow prompt/posting regression check with `ruby .github/pi/tests/prompt_test.rb` (requires Ruby, jq, and bash; stubs Pi/GitHub, no credentials or network).

When upgrading Pi, update both workflow version pins and verify the downloaded npm tarball SHA-256 before changing the recorded checksum.
