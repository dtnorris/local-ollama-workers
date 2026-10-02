# frozen_string_literal: true

require "json"

module LocalOllamaWorkers
  class ModelRequirement
    CONTRACT_VERSION = "adventurefinder-model-requirement/v0.1"
    ROOT_KEYS = %w[
      contract_version batch_handle production_batch_id plan_id plan_sha256
      alias pool_id required_labels ollama
    ].freeze
    OLLAMA_REQUIRED_KEYS = %w[
      model expected_digest required_context_length require_fully_gpu_resident
    ].freeze
    OLLAMA_OPTIONAL_KEYS = %w[required_gpu_id].freeze

    attr_reader :document

    def self.load(path)
      new(JSON.parse(File.binread(File.expand_path(path))))
    rescue JSON::ParserError => e
      raise Error, "invalid model requirement JSON: #{e.message}"
    rescue SystemCallError => e
      raise Error, "cannot read model requirement #{path}: #{e.message}"
    end

    def initialize(document)
      Contract.exact_keys!(document, ROOT_KEYS, "model requirement")
      unless document.fetch("contract_version") == CONTRACT_VERSION
        raise Error, "model requirement contract must be #{CONTRACT_VERSION}"
      end

      @document = JSON.parse(JSON.generate(document))
      validate_root!
      deep_freeze(@document)
      freeze
    rescue JSON::GeneratorError, JSON::ParserError, KeyError => e
      raise Error, "invalid model requirement: #{e.message}"
    end

    def model = ollama.fetch("model")
    def expected_digest = ollama.fetch("expected_digest")
    def required_context_length = ollama.fetch("required_context_length")
    def required_gpu_id = ollama["required_gpu_id"]

    def validate_preload!(installed:, gpu_id:)
      compare!(installed, "model", model)
      compare!(installed, "digest", expected_digest)
      return unless required_gpu_id && gpu_id != required_gpu_id

      raise Error, "gpu_id mismatch: expected #{required_gpu_id.inspect}, got #{gpu_id.inspect}"
    end

    def validate_observed!(running:, gpu_id:)
      validate_preload!(installed: running, gpu_id:)
      compare!(running, "context_length", required_context_length)
      compare!(running, "fully_gpu_resident", true)
    end

    private

    def validate_root!
      %w[batch_handle production_batch_id plan_id alias pool_id].each do |key|
        Contract.nonempty!(@document.fetch(key), key, max: 256)
      end
      digest!(@document.fetch("plan_sha256"), "plan_sha256")
      labels = @document.fetch("required_labels")
      Contract.strings!(labels, "required_labels")
      raise Error, "required_labels must be unique" unless labels.uniq == labels

      validate_ollama!(@document.fetch("ollama"))
    end

    def validate_ollama!(value)
      expected = OLLAMA_REQUIRED_KEYS + (value.is_a?(Hash) && value.key?("required_gpu_id") ? OLLAMA_OPTIONAL_KEYS : [])
      Contract.exact_keys!(value, expected, "model requirement ollama")
      Contract.nonempty!(value.fetch("model"), "ollama.model", max: 256)
      digest!(value.fetch("expected_digest"), "ollama.expected_digest")
      context = value.fetch("required_context_length")
      unless context.is_a?(Integer) && context.positive?
        raise Error, "ollama.required_context_length must be a positive integer"
      end
      unless value.fetch("require_fully_gpu_resident") == true
        raise Error, "ollama.require_fully_gpu_resident must be true"
      end

      return unless value.key?("required_gpu_id")

      Contract.nonempty!(value.fetch("required_gpu_id"), "ollama.required_gpu_id", max: 256)
    end

    def ollama = document.fetch("ollama")

    def digest!(value, label)
      raise Error, "#{label} must be a lowercase SHA-256" unless value.is_a?(String) && Contract::SHA256.match?(value)
    end

    def compare!(record, field, expected)
      actual = record[field]
      return if actual == expected

      raise Error, "#{field} mismatch: expected #{expected.inspect}, got #{actual.inspect}"
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each do |key, item|
          deep_freeze(key)
          deep_freeze(item)
        end
      when Array
        value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end
  end
end
