require_relative "test_helper"
require "tempfile"
require "delegate"

class TrackedIOTest < Minitest::Test
  include TestHelpers

  # Seekable, but with no size to go by
  class Unsized < SimpleDelegator
    def respond_to_missing?(name, include_private = false) = name != :size && super
  end

  def setup
    batches, output = recording
    @batches = batches
    @root = TaskProgress.new("root", outputs: [output])
    @task = @root.subtask("Reading")
  end

  def bytes(n) = StringIO.new("x" * n)

  def test_io_copy_stream_is_counted
    IO.copy_stream(@task.track_io(bytes(100_000)), StringIO.new)
    assert_equal 100_000, @task.count
    assert_equal 100_000, @task.total
    assert_equal "bytes", @task.node.unit
  end

  def test_small_reads_advance_in_steps_not_per_read
    io = @task.track_io(bytes(100_000))
    before = @root.log.seq
    io.read(1) until io.eof?
    assert_operator @root.log.seq - before, :<=, 1001, "a step is a thousandth of the total"
    assert_equal 100_000, @task.count, "reaching the total reports the rest"
  end

  def test_only_the_furthest_position_counts
    io = @task.track_io(bytes(10_000), step: 1)
    io.read(4000)
    io.seek(0)
    io.read(1000)
    assert_equal 4000, @task.count
    io.seek(8000)
    io.read(10)
    assert_equal 8010, @task.count, "a seek forward counts what was skipped, as the position says"
  end

  def test_line_reads_go_through_progressive_io
    io = @task.track_io(StringIO.new("one\ntwo\nthree\n"), step: 1)
    assert_equal %w[one two three], io.each_line.map(&:chomp)
    assert_equal 14, @task.count
  end

  def test_readpartial_sysread_and_read_nonblock_are_counted
    Tempfile.create("tracked") do |file|
      file.write("y" * 30_000)
      file.flush
      file.rewind
      io = @task.track_io(file, step: 1)
      io.readpartial(10_000)
      io.sysread(10_000)
      io.read_nonblock(10_000)
      assert_equal 30_000, @task.count
    end
  end

  def test_the_block_form_runs_the_task_and_reports_the_tail
    out = StringIO.new
    result = @task.track_io(bytes(5000), step: 10_000) { |io| IO.copy_stream(io, out) }
    assert_equal 5000, result
    assert_equal :done, @task.status
    assert_equal 5000, @task.count, "what never made a whole step is reported before done"
  end

  def test_the_block_form_fails_the_task_when_the_block_raises
    assert_raises(IOError) { @task.track_io(bytes(10)) { raise IOError, "disk gone" } }
    assert_equal :failed, @task.status
    assert_equal "disk gone", @task.error[:message]
  end

  def test_a_total_can_be_given_for_an_io_without_a_size
    io = @task.track_io(Unsized.new(bytes(2000)), total: 4000, step: 1)
    io.read(1000)
    assert_equal 25, @task.percent
  end

  def test_without_a_size_or_a_total_it_counts_bytes_with_no_measure
    io = @task.track_io(Unsized.new(bytes(200_000)))
    io.read
    assert @task.node.indeterminate
    assert_nil @task.total
    assert_equal 200_000, @task.count
  end

  def test_an_io_with_no_position_is_refused_with_advice
    reader, writer = IO.pipe
    error = assert_raises(ArgumentError) { @task.track_io(reader) }
    assert_match(/advance!/, error.message)
  ensure
    [reader, writer].each { it&.close }
  end

  def test_reads_after_the_task_finished_are_ignored
    io = @task.track_io(bytes(1000), step: 1)
    io.read(10)
    @task.done!
    io.read
    assert_equal :done, @task.status
  end
end
