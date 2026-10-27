# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # A stream store in Redis: each tree a Redis stream of its own (XADD, XREAD, XTRIM), its values in plain keys. It
  # takes a redis-client connection or pool (`RedisClient.config(url:).new_pool`), or a redis-rb
  # `Redis` - neither is a dependency of this gem, and nothing here loads one.
  #
  #     TaskProgress.stream_store = TaskProgress::RedisStreamStore.new(RedisClient.config(url: ENV["REDIS_URL"]).new_pool)
  #
  # Needs Redis 6.2 or later, for trimming by id. A reader that waits holds its connection for
  # as long as it waits - a pool sized for the readers that follow at once keeps the rest moving.
  # A redis-rb `Redis` is a single connection, so everything else on it waits too: give one that
  # follows trees a client of its own.
  #
  # A write with a `guard:` - a key and the value it must hold - runs as a Lua script, so the
  # check and the write are one step, see MemoryStreamStore
  class RedisStreamStore
    # The guarded writes. KEYS[1] is the guard, ARGV[1] the value it must hold
    GUARDED = {
      set: "if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end " \
        "if ARGV[3] == '' then redis.call('SET', KEYS[2], ARGV[2]) else redis.call('SET', KEYS[2], ARGV[2], 'PX', ARGV[3]) end return 1",
      trim: "if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end redis.call('XTRIM', KEYS[2], 'MINID', ARGV[2]) return 1",
      delete: "if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end for i = 2, #KEYS do redis.call('DEL', KEYS[i]) end return 1",
      expire: "if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end redis.call('PEXPIRE', KEYS[2], ARGV[2]) return 1"
    }.freeze #: Hash[Symbol, String]

    # @rbs @redis: untyped

    # For a redis-client connection or pool, or a redis-rb client
    #: (untyped) -> void
    def initialize(redis)
      @redis = redis
    end

    # Adds `data` at the end of the stream at `key`, and returns its id
    #: (String, String) -> String
    def append(key, data) = @redis.call("XADD", key, "*", "d", data).to_s

    # The entries after the id `after` - all of them when it is nil - as `[id, data]` pairs. With
    # a `timeout`, waits up to that many seconds for one to come when there are none yet
    #: (String, ?after: String?, ?timeout: (Integer | Float)?) -> Array[[String, String]]
    def read(key, after: nil, timeout: nil)
      after ||= "0-0"
      ms = (timeout * 1000).ceil if timeout&.positive?
      reply = if ms.nil?
        @redis.call("XREAD", "STREAMS", key, after)
      elsif @redis.respond_to?(:blocking_call)
        @redis.blocking_call(timeout.to_f + 1, "XREAD", "BLOCK", ms, "STREAMS", key, after)
      else
        # redis-rb knows to stretch its read timeout around a blocking command, but only in its own methods
        @redis.xread(key, after, block: ms)
      end
      entries(reply, key)
    end

    # The value at `key`, or nil
    #: (String) -> String?
    def get(key) = @redis.call("GET", key)

    # Keeps `value` at `key`, for `expires_in` seconds if given
    #: (String, String, ?expires_in: (Integer | Float)?, ?guard: [String, String]?) -> bool
    def set(key, value, expires_in: nil, guard: nil)
      ms = (expires_in * 1000).ceil if expires_in
      return guarded(:set, guard, [key], [value, ms.to_s]) if guard
      ms ? @redis.call("SET", key, value, "PX", ms) : @redis.call("SET", key, value)
      true
    end

    # Forgets the streams and values at these keys
    #: (*String, ?guard: [String, String]?) -> bool
    def delete(*keys, guard: nil)
      return true if keys.empty?
      return guarded(:delete, guard, keys, []) if guard
      @redis.call("DEL", *keys)
      true
    end

    # Drops the entries before the id `before`
    #: (String, before: String, ?guard: [String, String]?) -> bool
    def trim(key, before:, guard: nil)
      return guarded(:trim, guard, [key], [before]) if guard
      @redis.call("XTRIM", key, "MINID", before)
      true
    end

    # Forgets what is at `key` - a stream or a value - `seconds` from now
    #: (String, Integer | Float, ?guard: [String, String]?) -> bool
    def expire(key, seconds, guard: nil)
      ms = (seconds * 1000).ceil
      return guarded(:expire, guard, [key], [ms.to_s]) if guard
      @redis.call("PEXPIRE", key, ms)
      true
    end

    private

    #: (Symbol, [String, String], Array[String], Array[String]) -> bool
    def guarded(script, guard, keys, args)
      @redis.call("EVAL", GUARDED.fetch(script), keys.length + 1, guard[0], *keys, guard[1], *args).to_i == 1
    end

    # XREAD answers in one of three shapes - RESP3 a Hash, RESP2 nested Arrays, redis-rb a Hash
    # of Hashes - and nil when nothing came
    #: (untyped, String) -> Array[[String, String]]
    def entries(reply, key)
      found = case reply
      when Hash then reply[key]
      when Array then reply.find { it[0] == key }&.last
      end
      (found || []).filter_map do |id, fields|
        data = fields.is_a?(Hash) ? fields["d"] : fields.each_slice(2).find { it[0] == "d" }&.last
        [id.to_s, data.to_s] if data
      end
    end
  end
end
