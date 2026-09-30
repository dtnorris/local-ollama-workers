# frozen_string_literal: true

require_relative "test_helper"

class RegistryPublisherTest < Minitest::Test
  include LowTestSupport

  def test_empty_snapshot_has_canonical_time_and_exact_fields
    with_tmpdir do |root|
      publisher = publisher(root:, clock: -> { Time.utc(2030, 1, 1, 0, 0, 0, 999_999) })
      snapshot = publisher.snapshot

      assert_equal LocalOllamaWorkers::Contract::ROOT_KEYS.sort, snapshot.keys.sort
      assert_equal "low-publisher", snapshot.fetch("registry_id")
      assert_equal 1, snapshot.fetch("revision")
      assert_equal "2030-01-01T00:00:00Z", snapshot.fetch("published_at")
      assert_equal "2030-01-01T00:00:30Z", snapshot.fetch("expires_at")
      assert_empty snapshot.fetch("workers")
    end
  end

  def test_fixture_backed_observation_produces_valid_worker
    with_tmpdir do |root|
      snapshot = publisher(root:, worker_source: -> { [observation] }).snapshot
      worker = snapshot.fetch("workers").first

      assert_equal LocalOllamaWorkers::Contract::WORKER_KEYS.sort, worker.keys.sort
      assert_equal %w[inference ollama remote], worker.fetch("labels")
      assert_equal fixture_worker.fetch("capability_fingerprint"), worker.fetch("capability_fingerprint")
      assert_equal snapshot, LocalOllamaWorkers::Contract.validate_snapshot!(snapshot, now: NOW)
    end
  end

  def test_invalid_observation_does_not_advance_publisher_state
    with_tmpdir do |root|
      invalid = observation
      invalid["endpoint"] = "not-an-endpoint"
      instance = publisher(root:, worker_source: -> { [invalid] })

      assert_raises(LocalOllamaWorkers::Error) { instance.snapshot }
      refute File.exist?(File.join(root, LocalOllamaWorkers::PublisherState::STATE_FILE))
    end
  end

  def test_duplicate_workers_do_not_advance_publisher_state
    with_tmpdir do |root|
      instance = publisher(root:, worker_source: -> { [observation, observation] })

      assert_raises(LocalOllamaWorkers::Error) { instance.snapshot }
      refute File.exist?(File.join(root, LocalOllamaWorkers::PublisherState::STATE_FILE))
    end
  end

  private

  def publisher(root:, worker_source: nil, clock: -> { NOW })
    LocalOllamaWorkers::RegistryPublisher.new(
      state_root: root,
      worker_source:,
      clock:,
      id_generator: -> { "low-publisher" }
    )
  end
end
