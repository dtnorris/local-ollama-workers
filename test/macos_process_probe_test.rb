# frozen_string_literal: true

require_relative "test_helper"

class MacOSProcessProbeTest < Minitest::Test
  class Backend
    attr_reader :pids

    def initialize(value)
      @value = value
      @pids = []
    end

    def info(pid)
      @pids << pid
      @value
    end
  end

  def test_process_info_retains_only_generation_evidence_needed_by_observer
    backend = Backend.new(
      pid: 321,
      start_time_usec: 1_800_000_123_456_789,
      executable_path: "/Applications/Fictional/Ollama.app/Contents/Resources/ollama"
    )
    probe = LocalOllamaWorkers::MacOSProcessProbe.new(backend:)

    info = probe.info(321)

    assert_equal [321], backend.pids
    assert_equal 321, info.pid
    assert_equal 1_800_000_123_456_789, info.start_time_usec
    assert_equal "/Applications/Fictional/Ollama.app/Contents/Resources/ollama", info.executable_path
  end

  def test_pid_mismatch_or_incomplete_incarnation_evidence_is_nil
    [
      { pid: 999, start_time_usec: 10, executable_path: "/usr/bin/ollama" },
      { pid: 321, start_time_usec: 0, executable_path: "/usr/bin/ollama" },
      { pid: 321, start_time_usec: 10, executable_path: "" },
      nil
    ].each do |value|
      assert_nil LocalOllamaWorkers::MacOSProcessProbe.new(backend: Backend.new(value)).info(321)
    end
  end

  def test_native_backend_rejects_non_macos_platform_before_loading_libproc
    error = assert_raises(LocalOllamaWorkers::Error) do
      LocalOllamaWorkers::MacOSProcessProbe::LibprocBackend.new(platform: "x86_64-linux")
    end

    assert_includes error.message, "requires macOS"
  end
end
