# frozen_string_literal: true

require_relative "test_helper"

class MacOSListenerProbeTest < Minitest::Test
  Status = Struct.new(:exitstatus) do
    def success? = exitstatus.zero?
  end

  def test_argv_safe_lsof_query_returns_single_owner
    calls = []
    executor = lambda do |*argv|
      calls << argv
      ["p321\ncollama\nn127.0.0.1:11434\nn[::1]:11434\n", "", Status.new(0)]
    end
    probe = LocalOllamaWorkers::MacOSListenerProbe.new(executor:, executable: "/fixture/lsof")

    owner = probe.owner("http://127.0.0.1:11434")

    assert_equal 321, owner.pid
    assert_equal "ollama", owner.command
    assert_equal [[
      "/fixture/lsof", "-nP", "-a", "-iTCP:11434", "-sTCP:LISTEN", "-Fpcn"
    ]], calls
  end

  def test_no_listener_is_nil
    executor = ->(*) { ["", "", Status.new(1)] }
    probe = LocalOllamaWorkers::MacOSListenerProbe.new(executor:)

    assert_nil probe.owner("http://127.0.0.1:11434")
  end

  def test_multiple_process_owners_fail_closed
    executor = lambda do |*|
      ["p321\ncollama\nn127.0.0.1:11434\np654\ncollama\nn127.0.0.1:11434\n", "", Status.new(0)]
    end
    probe = LocalOllamaWorkers::MacOSListenerProbe.new(executor:)

    error = assert_raises(LocalOllamaWorkers::Error) { probe.owner("http://127.0.0.1:11434") }
    assert_includes error.message, "multiple listening process owners"
  end

  def test_inspection_failure_is_not_treated_as_no_listener
    executor = ->(*) { ["", "permission denied\n", Status.new(1)] }
    probe = LocalOllamaWorkers::MacOSListenerProbe.new(executor:)

    error = assert_raises(LocalOllamaWorkers::Error) { probe.owner("http://127.0.0.1:11434") }
    assert_includes error.message, "permission denied"
  end

  def test_invalid_pid_fails_closed
    executor = ->(*) { ["pnot-a-pid\ncollama\n", "", Status.new(0)] }
    probe = LocalOllamaWorkers::MacOSListenerProbe.new(executor:)

    error = assert_raises(LocalOllamaWorkers::Error) { probe.owner("http://127.0.0.1:11434") }
    assert_includes error.message, "invalid PID"
  end
end
