# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # A store kept in this process, for where `Rails.cache` is not to hand - tests, a Rack app that
  # runs its jobs in-process. Anything with `read`, `write` and `delete` will do as a store; this
  # is the smallest one, and is safe to share between threads
  class MemoryStore
    # @rbs @entries: Hash[String, untyped]
    # @rbs @lock: Thread::Mutex

    # An empty store
    #: () -> void
    def initialize
      @entries = {}
      @lock = Mutex.new
    end

    # What was written under `key`, or nil
    #: (String) -> untyped
    def read(key) = @lock.synchronize { @entries[key] }

    # Keeps `value` under `key`; options, such as `expires_in:`, are taken and ignored
    #: (String, untyped, **untyped) -> void
    def write(key, value, **) = @lock.synchronize { @entries[key] = value }

    # Forgets what is under `key`
    #: (String) -> void
    def delete(key) = @lock.synchronize { @entries.delete(key) }
  end
end
