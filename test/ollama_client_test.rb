# frozen_string_literal: true

require_relative "test_helper"

class OllamaClientTest < Minitest::Test
  ENDPOINT = "http://127.0.0.1:11434"
  MODEL = "fixture-model:latest"
  DIGEST = "a" * 64

  def test_reads_exact_installed_and_running_capability_evidence
    client = client_with(
      "/api/tags" => {
        "models" => [{ "name" => MODEL, "model" => MODEL, "digest" => DIGEST }]
      },
      "/api/ps" => {
        "models" => [{
          "name" => MODEL,
          "model" => MODEL,
          "digest" => DIGEST,
          "size" => 29_645_718_159,
          "size_vram" => 29_645_718_159,
          "context_length" => 131_072
        }]
      }
    )

    assert_equal [{ "model" => MODEL, "digest" => DIGEST }], client.installed_models
    assert_equal(
      [{
        "model" => MODEL,
        "digest" => DIGEST,
        "context_length" => 131_072,
        "fully_gpu_resident" => true,
        "runtime_size_bytes" => 29_645_718_159,
        "runtime_size_vram_bytes" => 29_645_718_159
      }],
      client.running_models
    )
  end

  def test_partial_runtime_residency_is_observed_as_false
    client = client_with(
      "/api/ps" => {
        "models" => [{
          "model" => MODEL,
          "digest" => DIGEST,
          "size" => 10_000,
          "size_vram" => 7_500,
          "context_length" => 65_536
        }]
      }
    )

    model = client.running_models.first

    assert_equal 65_536, model.fetch("context_length")
    assert_equal false, model.fetch("fully_gpu_resident")
  end

  def test_preload_is_empty_prompt_non_generative_and_uses_requested_context
    calls = []
    requester = lambda do |method, path, payload|
      calls << [method, path, payload]
      {
        "model" => MODEL,
        "response" => "",
        "done" => true,
        "done_reason" => "load"
      }
    end
    client = LocalOllamaWorkers::OllamaClient.new(endpoint: ENDPOINT, requester:)

    client.preload!(model: MODEL, context_length: 131_072)

    assert_equal :post, calls.first[0]
    assert_equal "/api/generate", calls.first[1]
    assert_equal(
      {
        "model" => MODEL,
        "prompt" => "",
        "stream" => false,
        "keep_alive" => "10m",
        "options" => { "num_ctx" => 131_072, "num_predict" => 0 }
      },
      calls.first[2]
    )
  end

  def test_malformed_runtime_evidence_fails_closed
    client = client_with(
      "/api/ps" => {
        "models" => [{
          "model" => MODEL,
          "digest" => "not-a-digest",
          "size" => 10,
          "size_vram" => 11,
          "context_length" => 4096
        }]
      }
    )

    assert_raises(LocalOllamaWorkers::Error) { client.running_models }
  end

  private

  def client_with(responses)
    requester = lambda do |_method, path, _payload|
      JSON.parse(JSON.generate(responses.fetch(path)))
    end
    LocalOllamaWorkers::OllamaClient.new(endpoint: ENDPOINT, requester:)
  end
end
