# frozen_string_literal: true

require_relative "test_helper"
require_relative "fixtures/dynamic-worker-registry-v0.1/conformance"

class ContractTest < Minitest::Test
  include LowTestSupport

  EXPECTED_FINGERPRINT = "2995693d958654b0074ed25377b7e0a82f06b78c8411f71dcc0b4f9a0a7ea621"

  def test_authoritative_fixture_hashes_are_pinned
    manifest = File.readlines(File.join(FIXTURE_ROOT, "SHA256SUMS"), chomp: true)
    manifest_paths = manifest.to_h do |line|
      expected, relative = line.split(/\s+/, 2)
      [relative, expected]
    end
    copied_paths = Dir[File.join(FIXTURE_ROOT, "**", "*")].select { |path| File.file?(path) }
    copied_paths = copied_paths.reject { |path| path.end_with?("SHA256SUMS") }
    copied_paths.map! { |path| path.delete_prefix("#{FIXTURE_ROOT}/") }

    assert_equal copied_paths.sort, manifest_paths.keys.sort
    manifest_paths.each do |relative, expected|
      actual = Digest::SHA256.file(File.join(FIXTURE_ROOT, relative)).hexdigest
      assert_equal expected, actual, relative
    end
  end

  def test_valid_authoritative_fixture_and_fingerprint
    document = fixture
    assert_same document, LocalOllamaWorkers::Contract.validate_snapshot!(document, now: NOW)
    assert_same document, DynamicWorkerRegistryV01::Conformance.validate_document!(document, now: NOW)
    worker = document.fetch("workers").first
    assert_equal EXPECTED_FINGERPRINT, worker.fetch("capability_fingerprint")
    assert_equal EXPECTED_FINGERPRINT, LocalOllamaWorkers::Contract.capability_fingerprint(worker)
  end

  def test_every_authoritative_invalid_fixture_fails_closed
    invalid_expectations.each do |relative, expected_message|
      path = File.join(FIXTURE_ROOT, relative)
      document = JSON.parse(File.binread(path))
      assert_raises(LocalOllamaWorkers::Error, File.basename(path)) do
        LocalOllamaWorkers::Contract.validate_snapshot!(document, now: NOW)
      end
      error = assert_raises(DynamicWorkerRegistryV01::Conformance::Error, File.basename(path)) do
        DynamicWorkerRegistryV01::Conformance.validate_bytes!(File.binread(path), now: NOW)
      end
      assert_includes error.message, expected_message
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

  def invalid_expectations
    path = File.join(FIXTURE_ROOT, "INVALID_EXPECTATIONS.tsv")
    File.readlines(path, chomp: true).to_h { |line| line.split("\t", 2) }
  end

  def model(worker)
    worker.dig("capabilities", "ollama", "models").first
  end
end
