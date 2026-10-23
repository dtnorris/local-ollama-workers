# frozen_string_literal: true

require_relative "../test/test_helper"
require_relative "../test/support/allocation_publication"

# Explicit opt-in proof against a read-only WLO checkout; ordinary LOW tests do
# not depend on WLO. Missing WLO_ROOT or runtime dependencies abort, never skip.
require File.join(ENV.fetch("WLO_ROOT"), "lib/workload_orchestrator")

# Composes real LOW publication bytes with real WLO registry acceptance, durable
# attempt binding and active-attempt reconciliation. Only external observations
# and time are synthetic; no command is dispatched and no inference is run.
class AllocationContinuityTest < Minitest::Test
  include LowTestSupport

  BREAK_HANDOFF = ARGV.delete("--break-handoff")

  # The reported allocation transition must advance the accepted snapshot while
  # keeping the original durable running attempt and dispatch availability.
  # --break-handoff corrupts the second public output: this same proof must fail.
  def test_allocation_transition_keeps_original_running_attempt
    with_journey do |publication, store, poll, attempt, metadata_path, before|
      original = File.binread(metadata_path)
      evidence = File.binread(publication.evidence_path)
      publication.running.merge!("size" => AllocationPublication::OBSERVED_SIZE,
                                 "size_vram" => AllocationPublication::OBSERVED_SIZE)
      publication.now += 1
      after = poll.call(break_handoff: BREAK_HANDOFF)

      assert_empty reconciler(store).reconcile!(after)
      assert_equal original, File.binread(metadata_path)
      assert_equal evidence, File.binread(publication.evidence_path)
      running = store.dynamic_running_attempts
      assert_equal [attempt.attempt_id], running.map(&:attempt_id)
      assert_equal attempt.worker_binding.metadata, running.first.worker_binding.metadata
      assert_equal attempt.worker_binding.tuple, after.ready_workers.first.execution_identity
      assert_operator after.registry.revision, :>, before.registry.revision
      refute_equal before.registry.sha256, after.registry.sha256
      assert after.last_reconciliation.values.all?(&:empty?)
      assert after.usable?
      refute store.dispatch_halted?
    end
  end

  # Generation and endpoint changes are rejected by LOW before publication;
  # WLO then records the genuine disappearance as in doubt and halts dispatch.
  def test_identity_changes_still_protect_the_active_attempt
    [["generation_id", "replacement"], ["endpoint", "http://127.0.0.1:11435"]].each do |field, value|
      with_journey do |publication, store, poll, attempt, metadata_path|
        publication.identities = [publication.identity.merge(field => value)]
        publication.now += 1
        poller = poll.call

        assert_empty poller.ready_workers
        assert_loss(store, poller, attempt, metadata_path, "worker_disappeared")
      end
    end
  end

  # A broken public handoff cannot silently establish continuity. WLO rejects
  # malformed bytes and retains its prior checkpoint; expiry still loses the
  # bound attempt and blocks dispatch, even if LOW continues reporting READY.
  def test_broken_handoff_is_rejected_and_source_expiry_remains_protected
    with_journey do |publication, store, poll, attempt, metadata_path, accepted|
      retained = accepted.accepted_checkpoint
      publication.now += 1
      error = assert_raises(WorkloadOrchestrator::Error) { poll.call(break_handoff: true) }
      assert_match(/JSON|registry/, error.message)
      assert_equal retained, accepted.accepted_checkpoint
      assert_equal "running", JSON.parse(File.binread(metadata_path)).fetch("status")

      publication.now += 31
      refute accepted.usable?
      assert_loss(store, accepted, attempt, metadata_path, "worker_source_expired")
    end
  end

  private

  # Yields a prepared disposable journey and its real initially bound attempt.
  # Each poll consumes actual LOW JSON through WLO's StaticWorkerSource and
  # reopens the same durable poller checkpoint. Validation errors propagate.
  def with_journey
    with_tmpdir("low-wlo-allocation-") do |root|
      # Resolve platform temp-directory aliases before WLO's linked-path guard.
      root = File.realpath(root)
      low_root = File.join(root, "low")
      FileUtils.mkdir_p(low_root)
      publication = AllocationPublication.new(root: low_root)
      checkpoint = File.join(root, "registry-checkpoint.json")
      poll = lambda do |break_handoff: false|
        bytes = "#{JSON.generate(publication.snapshot)}\n"
        bytes = bytes.byteslice(0, bytes.bytesize / 2) if break_handoff
        source = WorkloadOrchestrator::StaticWorkerSource.new(bytes)
        WorkloadOrchestrator::WorkerRegistryPoller.new(
          source:, checkpoint_path: checkpoint, clock: -> { publication.now }
        ).poll_once
      end
      poller = poll.call
      plan = synthetic_plan
      store = WorkloadOrchestrator::ExecutionStore.new(output_dir: File.join(root, "output"), plan:, workdir: root)
      store.prepare!
      store.start!
      assignment = WorkloadOrchestrator::DynamicScheduler.new(plan:, store:)
                                                      .assignments(workers: poller.ready_workers).fetch(0)
      attempt = store.record_dynamic_running!(job: assignment.job, worker: assignment.worker,
                                              environment_keys: [])
      metadata_path = File.join(store.output_dir, "runs/allocation-job/metadata.json")
      yield publication, store, poll, attempt, metadata_path, poller
    end
  end

  # Returns a validated provider-neutral synthetic plan; its argv is never run.
  # Invalid schema changes raise the real WLO plan validation error.
  def synthetic_plan
    WorkloadOrchestrator::Plan.new(JSON.generate(
      "contract_version" => "wlo-execution-plan/v0.3", "plan_id" => "allocation-continuity",
      "failure_policy" => { "max_consecutive_failures" => 2, "max_total_failures" => 3 },
      "pools" => [{ "pool_id" => "local", "requirements" => { "ollama" => {
        "model" => AllocationPublication::MODEL, "expected_digest" => AllocationPublication::DIGEST,
        "required_context_length" => 131_072, "require_fully_gpu_resident" => true
      } } }],
      "jobs" => [{ "job_id" => "allocation-job", "pool_id" => "local", "argv" => ["never-executed"] }]
    ))
  end

  # Returns the real loss reconciler for the supplied execution store; loss
  # persistence and validation errors propagate from reconcile! at the call site.
  def reconciler(store)
    WorkloadOrchestrator::DynamicWorkerLossReconciler.new(store:)
  end

  # Asserts durable in-doubt state and dispatch protection for a real accepted
  # checkpoint. Assertion failures identify missing or misclassified protection.
  def assert_loss(store, poller, attempt, metadata_path, reason)
    events = reconciler(store).reconcile!(poller)
    assert_equal [reason], events.map { |event| event.fetch("reason") }
    metadata = JSON.parse(File.binread(metadata_path))
    assert_equal "failed", metadata.fetch("status")
    assert_equal "dynamic_worker_loss_in_doubt", metadata.dig("evidence", "kind")
    assert_equal false, metadata.dig("evidence", "outcome_known")
    assert_equal attempt.worker_binding.metadata.fetch("worker_execution_identity"),
                 metadata.fetch("worker_execution_identity")
    assert store.dispatch_halted?
    assert_equal reason, store.dispatch_halt.fetch("error")
  end
end
