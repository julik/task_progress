# frozen_string_literal: true

require "json"

class TaskProgress
  # A batch as JSON, one object per line:
  #
  #   {"log":"k7p2qd9z4m","prev":11,"seq":12,"at":1730000000.123,"ops":[[["x3k0","00af"],"set",40],[["x3k0"],"note","Reading"]]}
  #
  # The reading side is meant for a writer we do not trust - a subprocess parsing hostile input,
  # a stream relayed from elsewhere - so nothing it sends is taken at its word: a batch with
  # anything wrong in it is dropped whole, numbers are clamped, strings scrubbed and cut, paths
  # bounded, and nothing in an error is ever turned into a class
  module Wire
    LINE_LIMIT = 4 * 1024 * 1024
    TEXT_LIMIT = 2000
    BACKTRACE_LINES = 200
    CAUSES = 3
    MAX_DEPTH = 32
    SEGMENT = /\A[0-9a-z]{1,16}\z/
    MAX_OPS = 100_000
    MAX_COUNT = 2**53
    STATUSES = %w[pending active done failed].freeze

    extend self

    def to_h(batch)
      {log: batch.log, prev: batch.prev, seq: batch.seq, at: batch.at,
       ops: batch.events.map { |e| e.value.nil? ? [e.path, e.op] : [e.path, e.op, e.value] }}
    end

    def dump(batch) = JSON.generate(to_h(batch))

    # A Batch, or nil when the line is anything but a valid one
    def parse(line)
      from_h(JSON.parse(line))
    rescue JSON::ParserError, EncodingError
      nil
    end

    def from_h(data)
      return unless data.is_a?(Hash)
      data = data.transform_keys(&:to_s)
      prev, seq, ops = data.values_at("prev", "seq", "ops")
      return unless prev.is_a?(Integer) && seq.is_a?(Integer) && prev >= 0 && seq > prev
      return unless ops.is_a?(Array) && ops.length <= MAX_OPS
      events = ops.map { event(it) || (return nil) }
      at = data["at"].is_a?(Numeric) ? data["at"].to_f : 0.0
      Batch.new(log: text(data["log"])&.slice(0, 64), prev:, seq:, at:, events: events.freeze)
    end

    # Reads batches until EOF. An overlong line is skipped, as is a garbled one, and a line
    # cut off by a writer that died is never yielded
    def each_batch(io, limit: LINE_LIMIT)
      io.binmode
      while (line = io.gets("\n", limit))
        if !line.end_with?("\n")
          line = io.gets("\n", limit) until line.nil? || line.end_with?("\n") if line.bytesize >= limit
          next
        end
        batch = parse(line)
        yield batch if batch
      end
    end

    def error_to_h(error, depth = 0)
      return {class: "RuntimeError", message: text(error.to_s)} unless error.is_a?(Exception)
      {
        class: error.class.name,
        message: text(error.message),
        backtrace: error.backtrace&.first(BACKTRACE_LINES),
        cause: (error_to_h(error.cause, depth + 1) if error.cause && depth < CAUSES)
      }.compact
    end

    # Every string that leaves or enters goes through here: valid UTF-8, and cut
    def text(value)
      return unless value.is_a?(String) || value.is_a?(Symbol)
      TaskProgress.utf8(value.to_s)[0, TEXT_LIMIT]
    end

    private

    def event(op)
      return unless op.is_a?(Array) && (2..3).cover?(op.length)
      path, name, value = op
      name = name.name if name.is_a?(Symbol)
      return unless (path = path(path)) && name.is_a?(String)
      op = OPS.find { it.name == name } or return
      value = value(op, value)
      return if value == :invalid
      Event.new(path:, op:, value:)
    end

    def path(path)
      return unless path.is_a?(Array) && path.length <= MAX_DEPTH
      return unless path.all? { it.is_a?(String) && it.match?(SEGMENT) }
      path.map { -it }.freeze
    end

    def value(op, value)
      case op
      when :open, :meta then attributes(value, stale: op == :meta)
      when :set then value.is_a?(Numeric) ? value.clamp(0, 100) : :invalid
      when :add then value.is_a?(Integer) ? value.clamp(-MAX_COUNT, MAX_COUNT) : :invalid
      when :note then text(value)
      when :say then text(value) || :invalid
      when :done, :prune then nil
      when :fail then value.is_a?(Hash) ? error(value) : :invalid
      when :put then node(value)
      end
    end

    def attributes(value, stale: false)
      return :invalid unless value.is_a?(Hash)
      value = value.transform_keys(&:to_s)
      attrs = {}
      attrs[:name] = text(value["name"]).to_s if value.key?("name")
      attrs[:total] = count(value["total"]) if value.key?("total")
      attrs[:weight] = value["weight"].to_f.clamp(0.0, 1e9) if value["weight"].is_a?(Numeric)
      attrs[:expect] = count(value["expect"]) if value.key?("expect")
      attrs[:indeterminate] = value["indeterminate"] == true if value.key?("indeterminate")
      attrs[:unit] = text(value["unit"])&.slice(0, 16) if value.key?("unit")
      attrs[:stale] = value["stale"] == true if stale && value.key?("stale")
      attrs
    end

    def node(value)
      attrs = attributes(value)
      return :invalid if attrs == :invalid
      value = value.transform_keys(&:to_s)
      status = value["status"].is_a?(Symbol) ? value["status"].name : value["status"]
      return :invalid unless STATUSES.include?(status)
      attrs.merge(
        status: status.to_sym,
        count: count(value["count"]) || 0,
        percent: value["percent"].is_a?(Numeric) ? value["percent"].clamp(0, 100) : 0,
        message: text(value["message"]),
        error: (error(value["error"]) if value["error"].is_a?(Hash)),
        stale: value["stale"] == true,
        opened_at: time(value["opened_at"]),
        started_at: time(value["started_at"]),
        finished_at: time(value["finished_at"])
      )
    end

    def count(value) = (value.clamp(0, MAX_COUNT) if value.is_a?(Integer))

    def time(value) = (value.to_f if value.is_a?(Numeric))

    def error(data, depth = 0)
      data = data.transform_keys(&:to_s)
      extra = data.except("class", "message", "backtrace", "cause")
        .select { |_, v| v == true || v == false || v.is_a?(Integer) }.first(8).to_h { |k, v| [k.to_sym, v] }
      cause = data["cause"]
      {
        class: text(data["class"]) || "unknown",
        message: text(data["message"]).to_s,
        backtrace: (Array(data["backtrace"]).first(BACKTRACE_LINES).filter_map { text(it) } if data.key?("backtrace")),
        cause: (error(cause, depth + 1) if cause.is_a?(Hash) && depth < CAUSES)
      }.compact.merge(extra.except(:class, :message, :backtrace, :cause))
    end
  end
end
