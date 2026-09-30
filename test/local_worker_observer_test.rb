# frozen_string_literal: true

require_relative "test_helper"

class LocalWorkerObserverTest < Minitest::Test
  Owner = LocalOllamaWorkers::MacOSListenerProbe::Owner
  ProcessInfo = LocalOllamaWorkers::MacOSProcessProbe::ProcessInfo

  class ListenerProbe
    def initialize(sequence)
      @sequence = sequence
      @index = 0
    end

    def owner(_endpoint)
      value = @sequence.fetch([@index, @sequence.length - 1].min)
      @index += 1
      value
    end
  end

  class ProcessProbe
    def initialize(sequence)
      @sequence = sequence
      @index = 0
    end

    def info(_pid)
      value = @sequence.fetch([@index, @sequence.length - 1].min)
      @index += 1
      value
    end
  end

  def test_repeated_observation_of_same_daemon_is_stable_and_opaque
    process = process_info(pid: 321, start_time_usec: 1_800_000_123_456_789)
    observer = observer(
      listener: ListenerProbe.new([owner(321)]),
      process: ProcessProbe.new([process])
    )

    first = observer.observe
    second = observer.observe

    assert_equal "local-ollama-1", first.fetch("worker_id")
    assert_equal "http://127.0.0.1:11434", first.fetch("endpoint")
    assert_equal first, second
    assert_match(/\Alow-macos-[0-9a-f]{64}\z/, first.fetch("generation_id"))
    refute_includes first.fetch("generation_id"), "synthetic"
    refute_includes first.fetch("generation_id"), "Applications"
  end

  def test_restart_or_pid_reuse_changes_generation_with_same_worker_and_endpoint
    first = observer(
      listener: ListenerProbe.new([owner(321)]),
      process: ProcessProbe.new([process_info(pid: 321, start_time_usec: 10_000_001)])
    ).observe
    replacement = observer(
      listener: ListenerProbe.new([owner(321)]),
      process: ProcessProbe.new([process_info(pid: 321, start_time_usec: 10_000_999)])
    ).observe

    assert_equal first.fetch("worker_id"), replacement.fetch("worker_id")
    assert_equal first.fetch("endpoint"), replacement.fetch("endpoint")
    refute_equal first.fetch("generation_id"), replacement.fetch("generation_id")
  end

  def test_endpoint_reuse_by_different_pid_changes_generation
    first = observer(
      listener: ListenerProbe.new([owner(321)]),
      process: ProcessProbe.new([process_info(pid: 321, start_time_usec: 10_000_001)])
    ).observe
    replacement = observer(
      listener: ListenerProbe.new([owner(654)]),
      process: ProcessProbe.new([process_info(pid: 654, start_time_usec: 10_000_001)])
    ).observe

    assert_equal first.fetch("endpoint"), replacement.fetch("endpoint")
    refute_equal first.fetch("generation_id"), replacement.fetch("generation_id")
  end

  def test_missing_listener_returns_nil_without_fabricating_generation
    instance = observer(
      listener: ListenerProbe.new([nil]),
      process: ProcessProbe.new([process_info])
    )

    assert_nil instance.observe
  end

  def test_non_ollama_listener_fails_closed
    instance = observer(
      listener: ListenerProbe.new([owner(321)]),
      process: ProcessProbe.new([process_info(executable_path: "/usr/bin/python3")])
    )

    error = assert_raises(LocalOllamaWorkers::Error) { instance.observe }
    assert_includes error.message, "not owned by an Ollama executable"
  end

  def test_listener_change_during_observation_fails_closed
    instance = observer(
      listener: ListenerProbe.new([owner(321), owner(654)]),
      process: ProcessProbe.new([process_info(pid: 321)])
    )

    error = assert_raises(LocalOllamaWorkers::Error) { instance.observe }
    assert_includes error.message, "listener changed during observation"
  end

  def test_process_incarnation_change_during_observation_fails_closed
    instance = observer(
      listener: ListenerProbe.new([owner(321)]),
      process: ProcessProbe.new([
        process_info(pid: 321, start_time_usec: 100),
        process_info(pid: 321, start_time_usec: 101)
      ])
    )

    error = assert_raises(LocalOllamaWorkers::Error) { instance.observe }
    assert_includes error.message, "process changed during observation"
  end

  def test_process_disappearance_during_observation_fails_closed
    instance = observer(
      listener: ListenerProbe.new([owner(321)]),
      process: ProcessProbe.new([nil])
    )

    error = assert_raises(LocalOllamaWorkers::Error) { instance.observe }
    assert_includes error.message, "cannot establish concrete"
  end

  def test_only_loopback_endpoints_are_allowed
    error = assert_raises(LocalOllamaWorkers::Error) do
      observer(
        endpoint: "http://192.0.2.10:11434",
        listener: ListenerProbe.new([nil]),
        process: ProcessProbe.new([nil])
      )
    end

    assert_includes error.message, "loopback"
  end

  private

  def observer(endpoint: "http://127.0.0.1:11434", listener:, process:)
    LocalOllamaWorkers::LocalWorkerObserver.new(
      worker_id: "local-ollama-1",
      endpoint:,
      listener_probe: listener,
      process_probe: process
    )
  end

  def owner(pid)
    Owner.new(pid:, command: "ollama")
  end

  def process_info(pid: 321, start_time_usec: 1_800_000_123_456_789,
                   executable_path: "/Applications/Fictional/Ollama.app/Contents/Resources/ollama")
    ProcessInfo.new(pid:, start_time_usec:, executable_path:)
  end
end
