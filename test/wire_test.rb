require_relative "test_helper"

class WireTest < Minitest::Test
  include TestHelpers

  def batches_from(text, **)
    [].tap { |all| TaskProgress::Wire.each_batch(StringIO.new(+text), **) { all << it } }
  end

  def line(ops, prev: 0, seq: 1) = JSON.generate(v: 1, log: "x", prev:, seq:, at: 1.5, ops:)

  def test_a_batch_dumps_to_one_line_and_parses_back
    batch = TaskProgress::Batch.new(log: "abc", prev: 4, seq: 5, at: 1.25, events: [
      TaskProgress::Event.new(path: ["x3k0", "00af"], op: :set, value: 40),
      TaskProgress::Event.new(path: [], op: :done)
    ])
    json = TaskProgress::Wire.dump(batch)
    refute_includes json, "\n"
    assert_equal '{"v":1,"log":"abc","prev":4,"seq":5,"at":1.25,"ops":[[["x3k0","00af"],"set",40],[[],"done"]]}', json
    assert_equal batch, TaskProgress::Wire.parse(json)
  end

  def test_a_batch_with_one_bad_op_is_dropped_whole
    good = [[[], "note", "fine"]]
    [
      [[[], "explode", 1]],
      [[[0], "set", 1]],
      [[["X3K0"], "set", 1]],
      [[["a/b"], "set", 1]],
      [[["a" * 17], "set", 1]],
      [[[], "set", "50"]],
      [[[], "add", 1.5]],
      [[[], "fail", "not a hash"]],
      [[[], "open", "not a hash"]],
      [[[], "put", {name: "x", status: "exploded"}]],
      [[["a"] * 33, "note", "too deep"]]
    ].each do |ops|
      assert_nil TaskProgress::Wire.parse(line(good + ops)), ops.inspect
    end
  end

  def test_the_numbering_must_make_sense
    assert_nil TaskProgress::Wire.parse(line([], prev: 3, seq: 3))
    assert_nil TaskProgress::Wire.parse(line([], prev: -1, seq: 3))
    assert_nil TaskProgress::Wire.parse(JSON.generate(prev: 0, seq: 1, ops: "nope"))
    assert TaskProgress::Wire.parse(line([], prev: 0, seq: 9)), "a squash or a merge spans many seqs"
  end

  def test_only_its_own_version_of_the_format_is_read
    assert TaskProgress::Wire.parse(line([]))
    assert_nil TaskProgress::Wire.parse(JSON.generate(log: "x", prev: 0, seq: 1, ops: [])), "no version, no batch"
    assert_nil TaskProgress::Wire.parse(JSON.generate(v: 2, log: "x", prev: 0, seq: 1, ops: [])), "a newer writer is not half understood"
  end

  def test_numbers_are_clamped_and_strings_scrubbed_and_cut
    batch = TaskProgress::Wire.parse(line([
      [[], "set", 500],
      [[], "note", "y" * 3000],
      [[], "add", 2**70],
      [[], "open", {name: "Broken \xE2 name".b.force_encoding("UTF-8").scrub, weight: -3, total: -1, junk: 1}]
    ]))
    set, note, add, open = batch.events
    assert_equal 100, set.value
    assert_equal TaskProgress::Wire::TEXT_LIMIT, note.value.length
    assert_equal TaskProgress::Wire::MAX_COUNT, add.value
    assert_equal({name: "Broken � name", total: 0, weight: 0.0}, open.value)
  end

  def test_an_error_never_becomes_anything_but_strings_and_flags
    batch = TaskProgress::Wire.parse(line([[[], "fail", {class: {"nested" => 1}, message: 7, backtrace: "one line",
      cause: "nope", input: true, extra: "string extras are dropped", class_name: [1]}]]))
    assert_equal({class: "unknown", message: "", backtrace: ["one line"], input: true}, batch.events.first.value)
  end

  def test_error_to_h_caps_the_cause_chain_and_the_message
    error = begin
      raise "level 0"
    rescue => e
      5.times.reduce(e) do |cause, i|
        raise "level #{i + 1}", cause: cause
      rescue => wrapped
        wrapped
      end
    end
    h = TaskProgress::Wire.error_to_h(error)
    depth = 0
    node = h
    depth += 1 while (node = node[:cause])
    assert_equal TaskProgress::Wire::CAUSES, depth
    assert_equal TaskProgress::Wire::TEXT_LIMIT, TaskProgress::Wire.error_to_h(RuntimeError.new("m" * 9000))[:message].length
  end

  def test_each_batch_skips_garbage_overlong_and_cut_lines
    good = line([[[], "note", "ok"]])
    text = ["not json", "[1,2]", line([[[], "note", "x" * 5000]]), good, '{"prev":0,"seq":1,"ops":[[[],"no'].join("\n")
    batches = batches_from(text, limit: 4096)
    assert_equal [["ok"]], batches.map { it.events.map(&:value) }
  end

  def test_each_batch_reads_nothing_from_nothing
    assert_empty batches_from("")
  end
end
