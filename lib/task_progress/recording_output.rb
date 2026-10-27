# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # Keeps every batch it gets, for a test to look through:
  #
  #     recording = TaskProgress::RecordingOutput.new
  #     Importer.new(progress: TaskProgress.new("Import", outputs: [recording])).run
  #     assert_includes recording.said, "Skipped 3 rows"
  #     assert_equal 1, recording.events(:fail).length
  #
  # Safe to share between threads
  class RecordingOutput
    # @rbs @batches: Array[Batch]
    # @rbs @lock: Thread::Mutex

    # Nothing recorded yet
    #: () -> void
    def initialize
      @batches = []
      @lock = Mutex.new
    end

    # Records the batch
    #: (Batch, Log) -> void
    def call(batch, _log) = @lock.synchronize { @batches << batch }

    # Every batch so far, in order
    #: () -> Array[Batch]
    def batches = @lock.synchronize { @batches.dup }

    # Every event so far, in order - only those with the op `op`, if given
    #: (?Symbol?) -> Array[Event]
    def events(op = nil) = batches.flat_map(&:events).select { op.nil? || it.op == op }

    # What the tree was told to `puts`, in order
    #: () -> Array[String]
    def said = events(:say).map { it.value.to_s }

    # The tree the batches make, as an outline - see TaskProgress#outline
    #: () -> Hash[Symbol, untyped]?
    def outline
      state = State.new
      batches.each do |batch|
        state = State.new if batch.reset?
        batch.events.each { state.apply(it, at: batch.at) }
      end
      TaskProgress.outline(state, []) unless state.empty?
    end
  end
end
