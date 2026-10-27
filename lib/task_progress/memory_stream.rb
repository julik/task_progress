# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # A stream kept in this process: what TaskProgress.stream is until told otherwise, and what
  # the tests and the bench run on. It does what RedisStream does - append-only entries under a
  # key, read from an id on and waited for, trimmed from the front, plus plain values that
  # expire - so a tree handed off here behaves as one handed off through Redis, as long as the
  # job runs in the same process.
  #
  # Ids are "n-0", like Redis's, and grow across all keys. Safe to share between threads
  class MemoryStream
    # @rbs @entries: Hash[String, Array[[Integer, String]]]
    # @rbs @values: Hash[String, String]
    # @rbs @expiries: Hash[String, Float]
    # @rbs @counter: Integer
    # @rbs @lock: Thread::Mutex
    # @rbs @appended: Thread::ConditionVariable

    # An empty stream
    #: () -> void
    def initialize
      @entries = {}
      @values = {}
      @expiries = {}
      @counter = 0
      @lock = Mutex.new
      @appended = ConditionVariable.new
    end

    # Adds `data` at the end of the stream at `key`, and returns its id
    #: (String, String) -> String
    def append(key, data)
      @lock.synchronize do
        expire_locked(key)
        id = @counter += 1
        (@entries[key] ||= []) << [id, data]
        @appended.broadcast
        "#{id}-0"
      end
    end

    # The entries after the id `after` - all of them when it is nil - as `[id, data]` pairs. With
    # a `timeout`, waits up to that many seconds for one to come when there are none yet
    #: (String, ?after: String?, ?timeout: (Integer | Float)?) -> Array[[String, String]]
    def read(key, after: nil, timeout: nil)
      floor = after.to_i
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout if timeout
      @lock.synchronize do
        loop do
          expire_locked(key)
          found = (@entries[key] || []).select { |id, _| id > floor }
          return found.map { |id, data| ["#{id}-0", data] } if found.any? || deadline.nil?
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return [] if left <= 0
          @appended.wait(@lock, left)
        end
      end
    end

    # The value at `key`, or nil
    #: (String) -> String?
    def get(key) = @lock.synchronize { expire_locked(key) || @values[key] }

    # Keeps `value` at `key`, for `expires_in` seconds if given
    #: (String, String, ?expires_in: (Integer | Float)?) -> void
    def set(key, value, expires_in: nil)
      @lock.synchronize do
        @values[key] = value
        expires_in ? @expiries[key] = now + expires_in : @expiries.delete(key)
      end
    end

    # Forgets the streams and values at these keys
    #: (*String) -> void
    def delete(*keys)
      @lock.synchronize { keys.each { forget(it) } }
    end

    # Drops the entries before the id `before`
    #: (String, before: String) -> void
    def trim(key, before:)
      floor = before.to_i
      @lock.synchronize { @entries[key]&.reject! { |id, _| id < floor } }
    end

    # Forgets what is at `key` - a stream or a value - `seconds` from now
    #: (String, Integer | Float) -> void
    def expire(key, seconds)
      @lock.synchronize { @expiries[key] = now + seconds if @entries.key?(key) || @values.key?(key) }
    end

    private

    #: () -> Float
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Always nil, so a reader can `||` past it
    #: (String) -> nil
    def expire_locked(key)
      expiry = @expiries[key]
      forget(key) if expiry && expiry <= now
      nil
    end

    #: (String) -> void
    def forget(key)
      @entries.delete(key)
      @values.delete(key)
      @expiries.delete(key)
    end
  end
end
