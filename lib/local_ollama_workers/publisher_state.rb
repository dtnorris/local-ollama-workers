# frozen_string_literal: true

require "English"
require "fileutils"
require "json"
require "securerandom"

module LocalOllamaWorkers
  class PublisherState
    STATE_FILE = "dynamic-worker-registry-v0.1-publisher.json"
    LOCK_FILE = ".dynamic-worker-registry-v0.1.lock"
    STATE_KEYS = %w[schema_version registry_id revision].freeze

    def initialize(root:, id_generator: nil, renamer: nil)
      @root = File.expand_path(root)
      @id_generator = id_generator || -> { "low-#{SecureRandom.hex(16)}" }
      @renamer = renamer || ->(source, destination) { File.rename(source, destination) }
    end

    def advance!
      FileUtils.mkdir_p(@root)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        current = load_state
        registry_id = current ? current.fetch("registry_id") : @id_generator.call
        Contract.id!(registry_id, "publisher registry_id")
        revision = current ? current.fetch("revision") + 1 : 1
        write_atomic("schema_version" => 1, "registry_id" => registry_id, "revision" => revision)
        [registry_id, revision]
      end
    rescue JSON::ParserError, SystemCallError, KeyError, TypeError, ArgumentError => e
      raise Error, "could not advance registry publication: #{e.message}"
    end

    private

    def lock_path = File.join(@root, LOCK_FILE)
    def state_path = File.join(@root, STATE_FILE)

    def load_state
      return nil unless File.file?(state_path)

      state = JSON.parse(File.binread(state_path))
      Contract.exact_keys!(state, STATE_KEYS, "publisher state")
      raise Error, "publisher state schema is invalid" unless state.fetch("schema_version") == 1

      Contract.id!(state.fetch("registry_id"), "publisher registry_id")
      Contract.revision!(state.fetch("revision"))
      state
    end

    def write_atomic(document)
      temporary = "#{state_path}.tmp.#{$PROCESS_ID}.#{Thread.current.object_id}.#{SecureRandom.hex(4)}"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write("#{JSON.generate(document)}\n")
        file.flush
        file.fsync
      end
      @renamer.call(temporary, state_path)
      sync_directory
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def sync_directory
      File.open(@root, File::RDONLY, &:fsync)
    rescue Errno::EINVAL, Errno::ENOTSUP
      # Some filesystems do not support directory fsync; the atomic rename still holds.
    end
  end
end
