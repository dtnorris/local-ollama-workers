# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "local_ollama_workers"

module LowTestSupport
  FIXTURE_ROOT = File.expand_path("fixtures/dynamic-worker-registry-v0.1", __dir__)
  NOW = Time.utc(2030, 1, 1, 0, 1, 0)

  def fixture
    JSON.parse(File.binread(File.join(FIXTURE_ROOT, "minimal-valid.json")))
  end

  def fixture_worker
    deep_copy(fixture.fetch("workers").first)
  end

  def observation
    fixture_worker.reject { |key, _value| key == "capability_fingerprint" }
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def with_tmpdir(prefix = "low-test-")
    Dir.mktmpdir(prefix) { |directory| yield directory }
  end
end

