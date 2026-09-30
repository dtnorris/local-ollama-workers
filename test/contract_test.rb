# frozen_string_literal: true

require_relative "test_helper"

class ContractTest < Minitest::Test
  include LowTestSupport

  EXPECTED_FINGERPRINT = "2995693d958654b0074ed25377b7e0a82f06b78c8411f71dcc0b4f9a0a7ea621"

  def test_authoritative_fixture_hashes_are_pinned
    manifest = File.readlines(File.join(FIXTURE_ROOT, "SHA256SUMS"), chomp: true)
    assert_equal 8, manifest.length

    manifest.each do |line|
      expected, relative = line.split(/\s+/, 2)
      actual = Digest::SHA256.file(File.join(FIXTURE_ROOT, relative)).hexdigest
      assert_equal expected, actual, relative
    end
  end

  def test_valid_authoritative_fixture_and_fingerprint
    document = fixture
    assert_same document, LocalOllamaWorkers::Contract.validate_snapshot!(document, now: NOW)
    worker = document.fetch("workers").first
    assert_equal EXPECTED_FINGERPRINT, worker.fetch("capability_fingerprint")
    assert_equal EXPECTED_FINGERPRINT, LocalOllamaWorkers::Contract.capability_fingerprint(worker)
  end

  def test_every_authoritative_invalid_fixture_fails_closed
    paths = Dir[File.join(FIXTURE_ROOT, "invalid", "*.json")].sort
    assert_equal 7, paths.length

    paths.each do |path|
      document = JSON.parse(File.binread(path))
      assert_raises(LocalOllamaWorkers::Error, File.basename(path)) do
        LocalOllamaWorkers::Contract.validate_snapshot!(document, now: NOW)
      end
    end
  end

  def test_valid_empty_registry_snapshot
    document = {
      "contract_version" => LocalOllamaWorkers::Contract::VERSION,
      "registry_id" => "low-fixture",
      "revision" => 0,
      "published_at" => "2030-01-01T00:00:00Z",
      "expires_at" => "2030-01-01T00:05:00Z",
      "workers" => []
    }

    assert_equal document, LocalOllamaWorkers::Contract.validate_snapshot!(document, now: NOW)
  end

  def test_exact_field_sets_are_required
    root_extra = fixture.merge("provider" => "local")
    worker_extra = fixture
    worker_extra.fetch("workers").first["provider"] = "local"

    assert_raises(LocalOllamaWorkers::Error) do
      LocalOllamaWorkers::Contract.validate_snapshot!(root_extra, now: NOW)
    end
    assert_raises(LocalOllamaWorkers::Error) do
      LocalOllamaWorkers::Contract.validate_snapshot!(worker_extra, now: NOW)
    end
  end

  def test_duplicate_model_identity_is_rejected
    document = fixture
    worker = document.fetch("workers").first
    second = deep_copy(worker.dig("capabilities", "ollama", "models").first)
    second["digest"] = "b" * 64
    worker.dig("capabilities", "ollama", "models") << second
    worker["capability_fingerprint"] = LocalOllamaWorkers::Contract.capability_fingerprint(worker)

    assert_raises(LocalOllamaWorkers::Error) do
      LocalOllamaWorkers::Contract.validate_snapshot!(document, now: NOW)
    end
  end

  def test_malformed_worker_scalars_are_rejected
    mutations = {
      "digest" => ->(worker) { model(worker)["digest"] = "ABC" },
      "context" => ->(worker) { model(worker)["context_length"] = 0 },
      "endpoint" => ->(worker) { worker["endpoint"] = "http://user@localhost:11434?bad=1" },
      "state" => ->(worker) { worker["state"] = "HEALTHY" }
    }

    mutations.each do |name, mutate|
      document = fixture
      worker = document.fetch("workers").first
      mutate.call(worker)
      worker["capability_fingerprint"] = LocalOllamaWorkers::Contract.capability_fingerprint(worker)
      assert_raises(LocalOllamaWorkers::Error, name) do
        LocalOllamaWorkers::Contract.validate_snapshot!(document, now: NOW)
      end
    end
  end

  private

  def model(worker)
    worker.dig("capabilities", "ollama", "models").first
  end
end
