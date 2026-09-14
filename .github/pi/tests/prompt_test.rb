# Runs the actual workflow shell blocks with local gh/pi stubs: no network or secrets.
require 'minitest/autorun'
require 'yaml'
require 'json'
require 'tmpdir'
require 'open3'

class PromptTest < Minitest::Test
  WORKFLOWS = File.expand_path('../../workflows', __dir__)
  NOTICE = '> **AI-generated, untrusted advice — not a review approval.'

  def steps(file)
    YAML.load_file(File.join(WORKFLOWS, file)).fetch('jobs').values.first.fetch('steps')
  end

  def run_step(file, name, env, dir)
    output, status = run_step_result(file, name, env, dir)
    assert status.success?, "#{name}: #{output}"
  end

  def run_step_result(file, name, env, dir)
    script = steps(file).find { |step| step['name'] == name }.fetch('run')
    Open3.capture2e(env, 'bash', '-c', script, chdir: dir)
  end

  def fixture(name)
    JSON.parse(File.read(File.join(__dir__, 'fixtures', name)))
  end

  def with_prompt(event, event_name = 'issue_comment')
    Dir.mktmpdir('pi-prompt-test') do |dir|
      File.write(File.join(dir, 'event.json'), JSON.generate(event))
      File.write(File.join(dir, 'node'), "#!/bin/bash\ncat > \"$RUNNER_TEMP/captured-prompt\"\nprintf 'Suggested fix\\n'\n")
      File.write(File.join(dir, 'gh'), <<~'SH')
        #!/bin/bash
        set -euo pipefail
        if [[ "$1 $2" == 'pr diff' ]]; then
          printf 'diff --git a/file.swift b/file.swift\n+flush()\n'
        elif [[ "$1" == api && "$2" == repos/*/pulls/* ]]; then
          printf '%s\n' "${HEAD_REPOSITORY:-example/repo}"
        elif [[ "$1" == api && "$2" == --paginate ]]; then
          printf '[]\n'
        else
          while [[ $# -gt 0 ]]; do
            if [[ "$1" == --body-file ]]; then cp "$2" "$RUNNER_TEMP/posted-comment"; exit 0; fi
            shift
          done
          exit 1
        fi
      SH
      %w[node gh].each { |file| File.chmod(0o755, File.join(dir, file)) }
      env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'RUNNER_TEMP' => dir,
              'GITHUB_EVENT_PATH' => File.join(dir, 'event.json'), 'EVENT_NAME' => event_name,
              'PI_CODING_AGENT_DIR' => dir, 'REPOSITORY' => 'example/repo',
              'OLLAMA_API_KEY' => 'fake-test-key', 'GH_TOKEN' => '' }
      run_step('pi-coding.yml', 'Build request context', env, dir)
      if event.dig('issue', 'pull_request')
        run_step('pi-coding.yml', 'Verify pull request source is trusted',
                 env.merge('PR_NUMBER' => event['issue']['number'].to_s), dir)
      end
      run_step('pi-coding.yml', 'Run Pi coding assistant', env, dir)
      run_step('pi-coding.yml', 'Post response', env, dir)
      posted_comment = File.read(File.join(dir, 'posted-comment'))
      assert posted_comment.start_with?(NOTICE)
      assert_includes posted_comment, 'Suggested fix'
      refute File.exist?(File.join(dir, 'injected'))
      yield File.read(File.join(dir, 'captured-prompt')), env, dir
    end
  end

  def test_issue_comment_includes_problem_separately_from_request
    event = fixture('issue-comment.json')
    with_prompt(event) do |prompt|
      assert_includes prompt, event['comment']['body']
      assert_includes prompt, "[BEGIN UNTRUSTED ISSUE OR PR TITLE AND DESCRIPTION]\n#{event['issue']['title']}\n\n#{event['issue']['body']}"
      refute_includes prompt, '[BEGIN UNTRUSTED PULL REQUEST DIFF]'
    end
  end

  def test_pr_comment_includes_description_and_diff_and_review_notice
    event = fixture('pr-comment.json')
    with_prompt(event) do |prompt, env, dir|
      assert_includes prompt, event['issue']['title']
      assert_includes prompt, event['issue']['body']
      assert_includes prompt, "[BEGIN UNTRUSTED PULL REQUEST DIFF]\ndiff --git"
      File.write(File.join(dir, 'review.md'), 'Model advice')
      run_step('pi-review.yml', 'Upsert review comment', env.merge('PR_NUMBER' => '456'), dir)
      posted_comment = File.read(File.join(dir, 'posted-comment'))
      assert posted_comment.start_with?("<!-- pi-code-review -->\n\n#{NOTICE}")
      assert_includes posted_comment, 'Model advice'
    end
  end

  def test_fork_pull_request_is_rejected
    Dir.mktmpdir('pi-fork-test') do |dir|
      File.write(File.join(dir, 'gh'), "#!/bin/bash\nprintf 'fork-owner/repo\\n'\n")
      File.chmod(0o755, File.join(dir, 'gh'))
      env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'REPOSITORY' => 'example/repo',
              'PR_NUMBER' => '456', 'GH_TOKEN' => 'fake-test-token' }

      output, status = run_step_result('pi-coding.yml', 'Verify pull request source is trusted', env, dir)

      refute status.success?
      assert_includes output, 'Fork pull requests are not eligible'
    end
  end

  def test_request_is_bounded_and_warns_when_truncated
    event = fixture('issue-comment.json')
    event['comment']['body'] = ('x' * 40000) + 'OMITTED_TAIL'
    with_prompt(event) do |prompt|
      assert_includes prompt, 'WARNING: Request truncated to 32768 bytes'
      request = prompt.split("WARNING: Request truncated to 32768 bytes; context is incomplete.\n", 2).last
                      .split("\n[END UNTRUSTED REQUEST]", 2).first
      assert_equal 32768, request.bytesize
      refute_includes prompt, 'OMITTED_TAIL'
      assert_includes prompt, '[END UNTRUSTED REQUEST]'
    end
  end

  def test_context_is_bounded_and_closing_delimiter_survives
    event = fixture('issue-comment.json')
    event['issue']['body'] = ('x' * 40000) + 'OMITTED_TAIL'
    with_prompt(event) do |prompt|
      assert_includes prompt, 'WARNING: Title/description truncated to 32768 bytes'
      context = prompt.split("context is incomplete.\n", 2).last.split("\n[END UNTRUSTED ISSUE OR PR TITLE AND DESCRIPTION]", 2).first
      assert_equal 32768, context.bytesize
      refute_includes prompt, 'OMITTED_TAIL'
      assert_includes prompt, '[END UNTRUSTED ISSUE OR PR TITLE AND DESCRIPTION]'
    end
  end

  def test_null_body_on_issue_event
    event = fixture('issue-comment.json')
    event['issue']['body'] = nil
    with_prompt(event, 'issues') do |prompt|
      assert_includes prompt, event['issue']['title']
      assert_includes prompt, '[END UNTRUSTED ISSUE OR PR TITLE AND DESCRIPTION]'
    end
  end
end
