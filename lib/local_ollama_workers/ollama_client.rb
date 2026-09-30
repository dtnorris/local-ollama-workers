# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module LocalOllamaWorkers
  class OllamaClient
    DEFAULT_KEEP_ALIVE = "10m"
    API_TIMEOUT_SECONDS = 600

    attr_reader :endpoint

    def initialize(endpoint:, requester: nil)
      @endpoint = Contract.normalized_endpoint(endpoint, "local Ollama endpoint")
      @requester = requester || method(:net_http_request)
    end

    def version
      document = request_json(:get, "/api/version")
      Contract.nonempty!(document.fetch("version"), "Ollama version", max: 128)
    rescue KeyError => e
      raise Error, "invalid Ollama version response: #{e.message}"
    end

    def installed_models
      models = model_array(request_json(:get, "/api/tags"), "installed")
      unique_models(models.map { |model| installed_model(model) }, "installed")
    end

    def running_models
      models = model_array(request_json(:get, "/api/ps"), "running")
      unique_models(models.map { |model| running_model(model) }, "running")
    end

    def preload!(model:, context_length:, keep_alive: DEFAULT_KEEP_ALIVE)
      model_id = Contract.nonempty!(model, "bootstrap model", max: 256)
      context = positive_integer(context_length, "bootstrap context length")
      duration = Contract.nonempty!(keep_alive, "bootstrap keep_alive", max: 32)
      response = request_json(
        :post,
        "/api/generate",
        "model" => model_id,
        "prompt" => "",
        "stream" => false,
        "keep_alive" => duration,
        "options" => { "num_ctx" => context, "num_predict" => 0 }
      )
      valid = response["model"] == model_id && response["done"] == true && response.fetch("response", "") == ""
      raise Error, "Ollama preload did not prove a non-generative load for #{model_id.inspect}" unless valid

      response
    end

    private

    def request_json(method, path, payload = nil)
      document = @requester.call(method, path, payload)
      raise Error, "Ollama #{path} response must be a JSON object" unless document.is_a?(Hash)

      document
    rescue Error
      raise
    rescue JSON::ParserError, SystemCallError, IOError, Timeout::Error, SocketError => e
      raise Error, "Ollama #{path} request failed: #{e.message}"
    end

    def net_http_request(method, path, payload)
      uri = URI.parse("#{@endpoint}#{path}")
      request = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
      if payload
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)
      end
      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 5,
        read_timeout: API_TIMEOUT_SECONDS
      ) { |http| http.request(request) }
      raise Error, "Ollama #{path} request returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end

    def model_array(document, label)
      models = document.fetch("models")
      raise Error, "Ollama #{label} models response must contain an array" unless models.is_a?(Array)

      models
    rescue KeyError => e
      raise Error, "invalid Ollama #{label} models response: #{e.message}"
    end

    def installed_model(model)
      raise Error, "Ollama installed model entry must be an object" unless model.is_a?(Hash)

      {
        "model" => model_id(model),
        "digest" => digest(model.fetch("digest"))
      }.freeze
    rescue KeyError => e
      raise Error, "invalid Ollama installed model entry: #{e.message}"
    end

    def running_model(model)
      raise Error, "Ollama running model entry must be an object" unless model.is_a?(Hash)

      size = nonnegative_integer(model.fetch("size"), "running model size")
      size_vram = nonnegative_integer(model.fetch("size_vram"), "running model size_vram")
      raise Error, "Ollama running model size must be positive" unless size.positive?
      raise Error, "Ollama running model size_vram exceeds size" if size_vram > size

      {
        "model" => model_id(model),
        "digest" => digest(model.fetch("digest")),
        "context_length" => positive_integer(model.fetch("context_length"), "running model context length"),
        "fully_gpu_resident" => size_vram == size,
        "runtime_size_bytes" => size,
        "runtime_size_vram_bytes" => size_vram
      }.freeze
    rescue KeyError => e
      raise Error, "invalid Ollama running model entry: #{e.message}"
    end

    def model_id(model)
      value = Contract.nonempty!(model.fetch("model"), "Ollama model identity", max: 256)
      name = model["name"]
      raise Error, "Ollama model name and runtime identity disagree" if name && name != value

      value
    end

    def digest(value)
      valid = value.is_a?(String) && Contract::SHA256.match?(value)
      raise Error, "Ollama model digest must be a lowercase SHA-256" unless valid

      value
    end

    def unique_models(models, label)
      names = models.map { |model| model.fetch("model") }
      raise Error, "Ollama #{label} model identities must be unique" unless names.uniq == names

      models.freeze
    end

    def positive_integer(value, label)
      number = nonnegative_integer(value, label)
      raise Error, "#{label} must be positive" unless number.positive?

      number
    end

    def nonnegative_integer(value, label)
      raise Error, "#{label} must be an integer" unless value.is_a?(Integer)
      raise Error, "#{label} must be non-negative" if value.negative?

      value
    end
  end
end
