# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/allocation_publication"

# Checks eligibility through actual API parsing, evidence validation and LOW
# publication, using only synthetic external observations and disposable state.
class AllocationPublicationTest < Minitest::Test
  include LowTestSupport

  # Reported larger and smaller fully resident allocations retain exact worker
  # identity/fingerprint and evidence bytes while publication metadata advances.
  def test_allocation_only_transitions_preserve_qualified_ready_worker
    with_tmpdir do |root|
      publication = AllocationPublication.new(root:)
      evidence = File.binread(publication.evidence_path)
      original = publication.snapshot
      [AllocationPublication::OBSERVED_SIZE, AllocationPublication::SAVED_SIZE - 1024].each do |size|
        publication.running.merge!("size" => size, "size_vram" => size)
        publication.now += 1
        current = publication.snapshot

        assert_equal "READY", current.fetch("workers").first&.fetch("state"), publication.source.diagnostic.inspect
        assert_equal original.fetch("workers"), current.fetch("workers")
        assert_equal original.fetch("registry_id"), current.fetch("registry_id")
        assert_operator current.fetch("revision"), :>, original.fetch("revision")
        assert_operator current.fetch("published_at"), :>, original.fetch("published_at")
        refute_equal Digest::SHA256.hexdigest(JSON.generate(original)), Digest::SHA256.hexdigest(JSON.generate(current))
        assert_equal evidence, File.binread(publication.evidence_path)
      end
    end
  end

  # A single size field can vary without changing residency only for a qualified
  # partial placement. Exercise both fields, larger/smaller, without false full GPU.
  def test_single_field_allocation_changes_preserve_qualified_partial_residency
    %w[size size_vram].each do |field|
      [-1024, 1024].each do |delta|
        with_tmpdir do |root|
          publication = AllocationPublication.new(root:, fully_gpu_resident: false)
          evidence = File.binread(publication.evidence_path)
          original = publication.snapshot
          publication.running[field] += delta
          publication.now += 1

          assert_equal original.fetch("workers"), publication.snapshot.fetch("workers")
          assert_equal false, original.dig("workers", 0, "capabilities", "ollama", "models", 0, "fully_gpu_resident")
          assert_equal evidence, File.binread(publication.evidence_path)
        end
      end
    end
  end

  # Real publication rejects material capability/runtime changes, even when
  # allocation drift is also present; persisted qualification is never rewritten.
  def test_material_capability_changes_still_omit_workers
    changes = [
      ["/api/tags", "digest", "b" * 64, "installed_model_mismatch"],
      ["/api/ps", "digest", "b" * 64, "running_model_mismatch"],
      ["/api/ps", "context_length", 262_144, "running_model_mismatch"],
      ["/api/ps", "size_vram", AllocationPublication::SAVED_SIZE - 1, "running_model_mismatch"]
    ]
    changes.each do |path, field, value, reason|
      with_tmpdir do |root|
        publication = AllocationPublication.new(root:)
        evidence = File.binread(publication.evidence_path)
        publication.inputs.fetch(path).fetch("models").first[field] = value

        assert_empty publication.snapshot.fetch("workers")
        assert_equal reason, publication.source.diagnostic.fetch("reason")
        assert_equal evidence, File.binread(publication.evidence_path)
      end
    end
    with_tmpdir do |root|
      publication = AllocationPublication.new(root:)
      publication.inputs.fetch("/api/version")["version"] = "0.34.0"
      assert_empty publication.snapshot.fetch("workers")
      assert_equal "version_mismatch", publication.source.diagnostic.fetch("reason")
    end
  end

  # First/second listener observations and evidence identity stay authoritative;
  # disappearing listeners and worker/generation/endpoint replacements cannot emit READY.
  def test_listener_and_execution_identity_changes_fail_closed
    [nil, ["worker_id", "replacement"], ["generation_id", "replacement"],
     ["endpoint", "http://127.0.0.1:11435"]].each do |change|
      with_tmpdir do |root|
        publication = AllocationPublication.new(root:)
        replacement = change ? publication.identity.merge(change.first => change.last) : nil
        publication.identities = [publication.identity, replacement]
        assert_empty publication.snapshot.fetch("workers")
        assert_equal "identity_changed", publication.source.diagnostic.fetch("reason")

        publication.identities = [replacement]
        assert_empty publication.snapshot.fetch("workers")
        expected = change ? (change.first == "endpoint" ? "endpoint_mismatch" : "evidence_identity_unavailable") :
          "listener_absent"
        assert_equal expected, publication.source.diagnostic.fetch("reason")
      end
    end
  end

  # Missing required fields and invalid numeric types/ranges are parser failures,
  # never successful omissions. A failed poll cannot advance publisher state.
  def test_malformed_runtime_observations_raise_without_advancing_revision
    invalid = %w[model digest context_length size size_vram].map { |field| [field, nil] }
    invalid += [
      ["model", 1], ["digest", "bad"], ["context_length", 0], ["context_length", "131072"],
      ["size", 0], ["size", -1], ["size", "13089594408"], ["size", 1.5], ["size", true],
      ["size_vram", -1], ["size_vram", "13089594408"], ["size_vram", 1.5], ["size_vram", false],
      ["size_vram", AllocationPublication::SAVED_SIZE + 1], ["name", "inconsistent-model"]
    ]
    invalid.each do |field, value|
      with_tmpdir do |root|
        publication = AllocationPublication.new(root:)
        publication.snapshot
        path = File.join(root, LocalOllamaWorkers::PublisherState::STATE_FILE)
        before = File.binread(path)
        value.nil? ? publication.running.delete(field) : publication.running[field] = value

        error = assert_raises(LocalOllamaWorkers::Error) { publication.snapshot }
        assert_match(/Ollama|running model/, error.message)
        assert_equal before, File.binread(path)
      end
    end
  end

  # Missing qualification is an omission; malformed or inconsistent evidence is
  # an error. Neither case may produce READY or fabricate replacement evidence.
  def test_missing_or_invalid_evidence_never_qualifies_a_worker
    with_tmpdir do |root|
      publication = AllocationPublication.new(root:)
      original = File.binread(publication.evidence_path)
      File.delete(publication.evidence_path)
      assert_empty publication.snapshot.fetch("workers")
      refute_path_exists publication.evidence_path

      invalid = JSON.parse(original)
      invalid.fetch("models").first["fully_gpu_resident"] = false
      ["{bad", JSON.generate(invalid)].each do |bytes|
        File.binwrite(publication.evidence_path, bytes)
        assert_raises(LocalOllamaWorkers::Error) { publication.snapshot }
        assert_equal bytes, File.binread(publication.evidence_path)
      end
    end
  end
end
