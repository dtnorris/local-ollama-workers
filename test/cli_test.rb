# frozen_string_literal: true

require_relative "test_helper"

class CLITest < Minitest::Test
  include LowTestSupport

  REPO_ROOT = File.expand_path("..", __dir__)

  def test_workers_json_emits_only_one_complete_snapshot_and_advances_revision
    with_tmpdir do |root|
      first_stdout, first_stderr, first_status = run_cli(root, "workers", "--json")
      second_stdout, second_stderr, second_status = run_cli(root, "workers", "--json")
      first = JSON.parse(first_stdout)
      second = JSON.parse(second_stdout)

      assert first_status.success?, first_stderr
      assert second_status.success?, second_stderr
      assert_empty first_stderr
      assert_empty second_stderr
      assert_equal 1, first_stdout.lines.length
      assert_equal 1, second_stdout.lines.length
      assert_equal LocalOllamaWorkers::Contract::VERSION, first.fetch("contract_version")
      assert_empty first.fetch("workers")
      assert_equal first.fetch("registry_id"), second.fetch("registry_id")
      assert_equal first.fetch("revision") + 1, second.fetch("revision")
    end
  end

  def test_invalid_arguments_fail_with_stderr_and_no_stdout
    with_tmpdir do |root|
      stdout, stderr, status = run_cli(root, "workers")

      refute status.success?
      assert_equal 2, status.exitstatus
      assert_empty stdout
      assert_includes stderr, "Usage: bin/low workers --json"
    end
  end

  def test_malformed_publisher_state_fails_with_nonzero_status
    with_tmpdir do |root|
      File.write(File.join(root, LocalOllamaWorkers::PublisherState::STATE_FILE), "{bad\n")
      stdout, stderr, status = run_cli(root, "workers", "--json")

      refute status.success?
      assert_equal 1, status.exitstatus
      assert_empty stdout
      assert_includes stderr, "ERROR: could not advance registry publication"
    end
  end

  private

  def run_cli(state_root, *arguments)
    Open3.capture3(
      { "LOW_STATE_ROOT" => state_root },
      RbConfig.ruby,
      File.join(REPO_ROOT, "bin", "low"),
      *arguments,
      chdir: REPO_ROOT
    )
  end
end

