# frozen_string_literal: true

require_relative "test_helper"

class PublisherStateTest < Minitest::Test
  include LowTestSupport

  def test_identity_is_stable_and_revision_advances
    with_tmpdir do |root|
      state = LocalOllamaWorkers::PublisherState.new(root:, id_generator: -> { "low-fixture" })

      assert_equal ["low-fixture", 1], state.advance!
      assert_equal ["low-fixture", 2], state.advance!
      persisted = JSON.parse(File.binread(File.join(root, LocalOllamaWorkers::PublisherState::STATE_FILE)))
      assert_equal({ "schema_version" => 1, "registry_id" => "low-fixture", "revision" => 2 }, persisted)
      assert_equal 0o600, File.stat(File.join(root, LocalOllamaWorkers::PublisherState::STATE_FILE)).mode & 0o777
    end
  end

  def test_concurrent_publications_cannot_reuse_a_revision
    with_tmpdir do |root|
      start = Queue.new
      results = Queue.new
      threads = 20.times.map do
        Thread.new do
          state = LocalOllamaWorkers::PublisherState.new(root:, id_generator: -> { "low-concurrent" })
          start.pop
          results << state.advance!
        end
      end
      threads.length.times { start << true }
      threads.each(&:join)
      publications = threads.length.times.map { results.pop }

      assert_equal ["low-concurrent"], publications.map(&:first).uniq
      assert_equal (1..threads.length).to_a, publications.map(&:last).sort
    end
  end

  def test_concurrent_processes_cannot_reuse_a_revision
    with_tmpdir do |root|
      pids = 8.times.map do |index|
        Process.fork do
          state = LocalOllamaWorkers::PublisherState.new(root:, id_generator: -> { "low-processes" })
          File.write(File.join(root, "result-#{index}.json"), JSON.generate(state.advance!))
          exit! 0
        end
      end
      statuses = pids.map { |pid| Process.wait2(pid).last }
      publications = Dir[File.join(root, "result-*.json")].sort.map do |path|
        JSON.parse(File.binread(path))
      end

      assert statuses.all?(&:success?)
      assert_equal ["low-processes"], publications.map(&:first).uniq
      assert_equal (1..pids.length).to_a, publications.map(&:last).sort
    end
  end

  def test_malformed_existing_state_fails_closed
    with_tmpdir do |root|
      path = File.join(root, LocalOllamaWorkers::PublisherState::STATE_FILE)
      File.write(path, "{not-json\n")
      state = LocalOllamaWorkers::PublisherState.new(root:)

      assert_raises(LocalOllamaWorkers::Error) { state.advance! }
      assert_equal "{not-json\n", File.binread(path)
    end
  end

  def test_failed_atomic_rename_preserves_previous_state_and_cleans_temporary_file
    with_tmpdir do |root|
      initial = LocalOllamaWorkers::PublisherState.new(root:, id_generator: -> { "low-atomic" })
      initial.advance!
      path = File.join(root, LocalOllamaWorkers::PublisherState::STATE_FILE)
      before = File.binread(path)
      failing = LocalOllamaWorkers::PublisherState.new(
        root:,
        renamer: ->(_source, _destination) { raise Errno::EIO, "fixture rename failure" }
      )

      assert_raises(LocalOllamaWorkers::Error) { failing.advance! }
      assert_equal before, File.binread(path)
      assert_empty Dir["#{path}.tmp.*"]
    end
  end
end
