# frozen_string_literal: true

require_relative "test_helper"

class CapabilityEvidenceStoreTest < Minitest::Test
  include LowTestSupport

  def test_persists_auditable_generation_bound_evidence_atomically
    with_tmpdir do |root|
      store = LocalOllamaWorkers::CapabilityEvidenceStore.new(root:)

      document = store.record!(
        identity: identity,
        ollama_version: "0.33.0",
        gpu_id: "Apple M4 Pro 20-core GPU",
        model: evidence_model
      )

      path = File.join(root, LocalOllamaWorkers::CapabilityEvidenceStore::EVIDENCE_FILE)
      assert_equal document, JSON.parse(File.binread(path))
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal identity.fetch("generation_id"), document.fetch("generation_id")
      assert_equal 131_072, document.fetch("models").first.fetch("context_length")
      assert_equal true, document.fetch("models").first.fetch("fully_gpu_resident")
      assert_equal "ollama-api-ps-size-vram", document.fetch("models").first.fetch("source")
      assert store.present?
    end
  end

  def test_same_generation_reuses_and_merges_model_evidence
    with_tmpdir do |root|
      store = LocalOllamaWorkers::CapabilityEvidenceStore.new(root:)
      record(store)
      second = evidence_model.merge(
        "model" => "second:latest",
        "digest" => "b" * 64,
        "context_length" => 65_536,
        "runtime_size_bytes" => 20_000,
        "runtime_size_vram_bytes" => 20_000
      )

      document = record(store, model: second)

      assert_equal %w[fixture-model:latest second:latest],
                   document.fetch("models").map { |model| model.fetch("model") }
      assert_equal document, store.load_for(identity)
    end
  end

  def test_new_generation_invalidates_prior_evidence_even_with_same_endpoint_and_model
    with_tmpdir do |root|
      store = LocalOllamaWorkers::CapabilityEvidenceStore.new(root:)
      record(store)
      replacement = identity.merge("generation_id" => "low-macos-#{"b" * 64}")

      assert_nil store.load_for(replacement)

      document = record(store, identity: replacement)

      assert_equal replacement.fetch("generation_id"), document.fetch("generation_id")
      assert_nil store.load_for(identity)
      assert_equal 1, document.fetch("models").length
      assert_equal evidence_model.fetch("digest"), document.fetch("models").first.fetch("digest")
    end
  end

  def test_malformed_or_internally_inconsistent_evidence_fails_closed
    with_tmpdir do |root|
      path = File.join(root, LocalOllamaWorkers::CapabilityEvidenceStore::EVIDENCE_FILE)
      File.write(path, "{not-json\n")
      store = LocalOllamaWorkers::CapabilityEvidenceStore.new(root:)

      assert_raises(LocalOllamaWorkers::Error) { store.load_for(identity) }

      File.write(path, JSON.generate(record_document(
        evidence_model.merge("fully_gpu_resident" => false)
      )))
      assert_raises(LocalOllamaWorkers::Error) { store.load_for(identity) }
    end
  end

  def test_failed_atomic_rename_preserves_previous_evidence_and_cleans_temporary_file
    with_tmpdir do |root|
      initial = LocalOllamaWorkers::CapabilityEvidenceStore.new(root:)
      before = record(initial)
      path = File.join(root, LocalOllamaWorkers::CapabilityEvidenceStore::EVIDENCE_FILE)
      failing = LocalOllamaWorkers::CapabilityEvidenceStore.new(
        root:,
        renamer: ->(_source, _destination) { raise Errno::EIO, "fixture rename failure" }
      )

      assert_raises(LocalOllamaWorkers::Error) do
        record(failing, model: evidence_model.merge("context_length" => 65_536))
      end
      assert_equal before, JSON.parse(File.binread(path))
      assert_empty Dir["#{path}.tmp.*"]
    end
  end

  private

  def identity
    {
      "worker_id" => "local-ollama-1",
      "generation_id" => "low-macos-#{"a" * 64}",
      "endpoint" => "http://127.0.0.1:11434"
    }
  end

  def evidence_model
    {
      "model" => "fixture-model:latest",
      "digest" => "a" * 64,
      "context_length" => 131_072,
      "fully_gpu_resident" => true,
      "observed_at" => "2030-01-01T00:01:00Z",
      "runtime_size_bytes" => 30_000,
      "runtime_size_vram_bytes" => 30_000,
      "source" => "ollama-api-ps-size-vram"
    }
  end

  def record(store, identity: self.identity, model: evidence_model)
    store.record!(
      identity:,
      ollama_version: "0.33.0",
      gpu_id: "Apple M4 Pro 20-core GPU",
      model:
    )
  end

  def record_document(model)
    {
      "schema_version" => 1,
      "worker_id" => identity.fetch("worker_id"),
      "generation_id" => identity.fetch("generation_id"),
      "endpoint" => identity.fetch("endpoint"),
      "ollama_version" => "0.33.0",
      "gpu_id" => "Apple M4 Pro 20-core GPU",
      "models" => [model]
    }
  end
end
