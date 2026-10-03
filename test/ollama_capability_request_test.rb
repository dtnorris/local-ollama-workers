# frozen_string_literal: true

require_relative "test_helper"

class OllamaCapabilityRequestTest < Minitest::Test
  EXPECTED_NORMALIZED_JSON = <<~JSON.chomp.freeze
    {"ollama":{"model":"qualified-model:latest","expected_digest":"#{'a' * 64}","required_context_length":131072,"require_fully_gpu_resident":true,"required_gpu_id":"NVIDIA A40"}}
  JSON
  EXPECTED_FINGERPRINT = "9121fe00d663bad2e5bd6f2ff4d6b492e66ba71b0843585c547321172dce5ae4"

  def test_canonical_generic_request_is_accepted
    request = build_request(canonical_document)

    assert_equal "ollama-capability-request/v0.1", request.contract_version
    assert_equal "qualified-model:latest", request.model
    assert_equal "a" * 64, request.expected_digest
    assert_equal 131_072, request.required_context_length
    assert request.require_fully_gpu_resident
    assert_equal "NVIDIA A40", request.required_gpu_id
    assert_equal EXPECTED_NORMALIZED_JSON, request.normalized_json
    assert_equal EXPECTED_FINGERPRINT, request.fingerprint
  end

  def test_normalization_is_independent_of_input_key_order
    document = canonical_document
    reordered = {
      "ollama" => document.fetch("ollama").to_a.reverse.to_h,
      "contract_version" => document.fetch("contract_version")
    }

    assert_equal build_request(document).normalized_json, build_request(reordered).normalized_json
    assert_equal build_request(document).fingerprint, build_request(reordered).fingerprint
  end

  def test_adventurefinder_and_orchestration_fields_are_rejected
    %w[
      batch_handle production_batch_id alias model_alias pool_id plan_id plan_sha256
      required_labels provenance provider_id fleet_id campaign_id
    ].each do |field|
      document = canonical_document.merge(field => "external-provenance")
      error = assert_raises(LocalOllamaWorkers::Error, field) { build_request(document) }

      assert_includes error.message, "unknown fields: #{field}", field
    end
  end

  def test_legacy_adventurefinder_envelope_is_rejected
    legacy = {
      "contract_version" => "adventurefinder-model-requirement/v0.1",
      "batch_handle" => "39",
      "production_batch_id" => "production-batch-039",
      "plan_id" => "production-batch-039",
      "plan_sha256" => "d" * 64,
      "alias" => "qwen27",
      "pool_id" => "qwen27",
      "required_labels" => ["inference"],
      "ollama" => canonical_document.fetch("ollama")
    }

    assert_raises(LocalOllamaWorkers::Error) { build_request(legacy) }
  end

  def test_malformed_runtime_fields_fail_closed
    invalid_values = {
      "model" => ["", " model", "model\n", 1, nil, "m" * 257],
      "expected_digest" => ["a" * 63, "A" * 64, "g" * 64, 1, nil],
      "required_context_length" => [0, -1, 1.0, "131072", true, nil],
      "require_fully_gpu_resident" => [1, 0, "true", nil],
      "required_gpu_id" => ["", " GPU", "GPU\n", 1, nil, "g" * 257]
    }

    invalid_values.each do |field, values|
      values.each do |value|
        document = canonical_document
        document.fetch("ollama")[field] = value
        assert_raises(LocalOllamaWorkers::Error, "#{field}=#{value.inspect}") do
          build_request(document)
        end
      end
    end
  end

  def test_contract_structure_and_duplicate_keys_fail_closed
    wrong_version = canonical_document.merge("contract_version" => "ollama-capability-request/v9")
    assert_raises(LocalOllamaWorkers::Error) { build_request(wrong_version) }

    %w[contract_version ollama].each do |field|
      document = canonical_document.reject { |key, _value| key == field }
      assert_raises(LocalOllamaWorkers::Error, field) { build_request(document) }
    end

    %w[model expected_digest required_context_length require_fully_gpu_resident].each do |field|
      document = canonical_document
      document.fetch("ollama").delete(field)
      assert_raises(LocalOllamaWorkers::Error, field) { build_request(document) }
    end

    assert_raises(LocalOllamaWorkers::Error) do
      build_request(canonical_document.merge("unknown" => true))
    end
    document = canonical_document
    document.fetch("ollama")["unknown"] = true
    assert_raises(LocalOllamaWorkers::Error) { build_request(document) }

    duplicate = <<~JSON
      {"contract_version":"ollama-capability-request/v0.1","contract_version":"ollama-capability-request/v0.1","ollama":{}}
    JSON
    assert_raises(LocalOllamaWorkers::Error) do
      LocalOllamaWorkers::OllamaCapabilityRequest.new(duplicate)
    end
  end

  def test_optional_gpu_id_may_be_absent
    document = canonical_document
    document.fetch("ollama").delete("required_gpu_id")
    request = build_request(document)

    assert_nil request.required_gpu_id
    refute request.normalized_request.fetch("ollama").key?("required_gpu_id")
    assert_equal "f4c5e1c85bd19070bb7529dd8683796db6727269ec730a58fd89c26c36be2546",
                 request.fingerprint
  end

  private

  def canonical_document
    {
      "contract_version" => "ollama-capability-request/v0.1",
      "ollama" => {
        "model" => "qualified-model:latest",
        "expected_digest" => "a" * 64,
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => true,
        "required_gpu_id" => "NVIDIA A40"
      }
    }
  end

  def build_request(document)
    LocalOllamaWorkers::OllamaCapabilityRequest.new(JSON.generate(document))
  end
end
