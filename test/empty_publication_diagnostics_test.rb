# frozen_string_literal: true

require_relative "test_helper"

# Verifies the separate diagnostic channel with the real parser, evidence store,
# source and publisher. All API documents and identities are synthetic.
class EmptyPublicationDiagnosticsTest < Minitest::Test
  include LowTestSupport

  # Exercises the CLI in a disposable state root, returning the status and both
  # channels. The caller may alter synthetic inputs or state before publication.
  def with_publication(stderr: StringIO.new)
    with_tmpdir do |root|
      document = JSON.parse(File.read(File.join(__dir__, "fixtures/empty-publication-evidence.json")))
      identity = document.slice("worker_id", "generation_id", "endpoint")
      inputs = {
        "/api/version" => { "version" => document.fetch("ollama_version") },
        "/api/tags" => { "models" => document.fetch("models").map { |m| m.slice("model", "digest") } },
        "/api/ps" => { "models" => document.fetch("models").map do |model|
          model.slice("model", "digest", "context_length").merge(
            "size" => model.fetch("runtime_size_bytes"), "size_vram" => model.fetch("runtime_size_vram_bytes")
          )
        end }
      }
      calls = []
      observer = Object.new
      observer.define_singleton_method(:observe) { identity }
      requester = lambda do |method, path, payload|
        raise "Unexpected mutation" unless method == :get && payload.nil?

        calls << path
        response = inputs.fetch(path)
        raise response if response.is_a?(Exception)

        response
      end
      evidence_path = File.join(root, LocalOllamaWorkers::CapabilityEvidenceStore::EVIDENCE_FILE)
      File.write(evidence_path, JSON.generate(document))
      stdout = StringIO.new
      publish = lambda do
        LocalOllamaWorkers::CLI.run(
          ["workers", "--json"], env: { "LOW_STATE_ROOT" => root }, stdout:, stderr:,
          components: {
            observer:,
            client: LocalOllamaWorkers::OllamaClient.new(endpoint: identity.fetch("endpoint"), requester:),
            evidence_store: LocalOllamaWorkers::CapabilityEvidenceStore.new(root:)
          }
        )
      end
      yield publish, stdout, stderr, inputs, document, root, calls, observer
    end
  end

  # Context remains material even with allocation drift and unchanged residency.
  def test_context_drift_has_exact_comparison_hash_and_returned_revision
    with_publication do |publish, stdout, stderr, inputs, document, _root, calls|
      running = inputs.fetch("/api/ps").fetch("models")[1]
      %w[size size_vram].each { |key| running[key] += 1 }
      running["context_length"] = 262_144
      assert_equal 0, publish.call
      snapshot = JSON.parse(stdout.string)
      diagnostic = JSON.parse(stderr.string)
      assert_empty snapshot.fetch("workers")
      assert_equal 1, stdout.string.lines.length
      assert_equal 1, stderr.string.lines.length
      assert_equal LocalOllamaWorkers::Contract::ROOT_KEYS.sort, snapshot.keys.sort
      assert_equal snapshot, LocalOllamaWorkers::Contract.validate_snapshot!(snapshot)
      assert_equal "low_empty_publication", diagnostic.fetch("event")
      assert_equal "running_model_mismatch", diagnostic.fetch("reason")
      %w[registry_id revision published_at].each { |key| assert_equal snapshot.fetch(key), diagnostic.fetch(key) }
      assert_equal "gpt-oss:20b-candidate", diagnostic.dig("expected", "model")
      assert_equal 131_072, diagnostic.dig("expected", "context_length")
      assert_equal 262_144, diagnostic.dig("observed", "context_length")
      assert_equal 40_000, diagnostic.dig("expected", "runtime_size_bytes")
      assert_equal 40_001, diagnostic.dig("observed", "runtime_size_bytes")
      assert_equal 40_000, diagnostic.dig("expected", "runtime_size_vram_bytes")
      assert_equal 40_001, diagnostic.dig("observed", "runtime_size_vram_bytes")
      assert_equal true, diagnostic.dig("observed", "fully_gpu_resident")
      assert_equal Digest::SHA256.hexdigest(JSON.generate(document)), diagnostic.fetch("evidence_sha256")
      assert_equal document.slice("worker_id", "generation_id", "endpoint"), diagnostic.fetch("evidence_identity")
      assert_kind_of Time, Time.iso8601(diagnostic.fetch("observed_at"))
      assert_equal %w[/api/version /api/tags /api/ps], calls
      assert_operator stderr.string.bytesize, :<, 8192
      refute_includes stderr.string, "gpu_id"
      refute_includes stderr.string, "source"
    end
  end

  # A generation mismatch retains the identity/hash of the exact rejected evidence.
  def test_stale_evidence_identity_is_visible_without_extra_api_reads
    with_publication do |publish, stdout, stderr, _inputs, document, root, calls|
      document["generation_id"] = "low-macos-#{'f' * 64}"
      File.write(File.join(root, LocalOllamaWorkers::CapabilityEvidenceStore::EVIDENCE_FILE), JSON.generate(document))
      assert_equal 0, publish.call
      assert_empty JSON.parse(stdout.string).fetch("workers")
      diagnostic = JSON.parse(stderr.string)
      assert_equal "evidence_identity_unavailable", diagnostic.fetch("reason")
      assert_equal document.fetch("generation_id"), diagnostic.dig("expected", "generation_id")
      refute_equal diagnostic.dig("expected", "generation_id"), diagnostic.dig("observed", "generation_id")
      assert_equal Digest::SHA256.hexdigest(JSON.generate(document)), diagnostic.fetch("evidence_sha256")
      assert_empty calls
    end
  end

  # Unloaded models are allowed; no diagnostic is emitted for a READY snapshot.
  def test_empty_ps_retains_ready_and_silent_stderr
    with_publication do |publish, stdout, stderr, inputs|
      inputs["/api/ps"] = { "models" => [] }
      assert_equal 0, publish.call
      assert_equal 1, JSON.parse(stdout.string).fetch("workers").length
      assert_empty stderr.string
    end
  end

  # Failed API parsing and timeouts retain the existing error channel and revision.
  def test_api_failures_do_not_publish_or_advance_state
    [Timeout::Error.new("secret timeout payload"), { "models" => [{}] }].each do |response|
      with_publication do |publish, stdout, stderr, inputs, _document, root|
        inputs["/api/ps"] = response
        assert_equal 1, publish.call
        assert_empty stdout.string
        assert_match(/\AERROR:/, stderr.string)
        refute_includes stderr.string, "low_empty_publication"
        refute File.exist?(File.join(root, LocalOllamaWorkers::PublisherState::STATE_FILE))
      end
    end
  end

  # Failed publisher persistence must not be reported as a successful omission.
  def test_publisher_failure_does_not_emit_success_diagnostic
    with_publication do |publish, stdout, stderr, inputs, _document, root|
      inputs["/api/tags"] = { "models" => [] }
      File.write(File.join(root, LocalOllamaWorkers::PublisherState::STATE_FILE), "{bad")
      assert_equal 1, publish.call
      assert_empty stdout.string
      assert_match(/\AERROR:/, stderr.string)
      refute_includes stderr.string, "low_empty_publication"
    end
  end

  # A closed stderr must not turn an already-published snapshot into a failed poll.
  def test_diagnostic_write_failure_preserves_success
    closed = StringIO.new
    closed.close
    with_publication(stderr: closed) do |publish, stdout, _stderr, inputs|
      inputs["/api/tags"] = { "models" => [] }
      assert_equal 0, publish.call
      assert_empty JSON.parse(stdout.string).fetch("workers")
    end
  end

  # Internal observer races remain errors rather than successful empty snapshots.
  def test_observer_race_does_not_emit_success_diagnostic
    with_publication do |publish, stdout, stderr, _inputs, _document, root, _calls, observer|
      observer.singleton_class.remove_method(:observe)
      observer.define_singleton_method(:observe) { raise LocalOllamaWorkers::Error, "synthetic listener race" }
      assert_equal 1, publish.call
      assert_empty stdout.string
      refute_includes stderr.string, "low_empty_publication"
      refute File.exist?(File.join(root, LocalOllamaWorkers::PublisherState::STATE_FILE))
    end
  end
end
