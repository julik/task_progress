require_relative "test_helper"

# What an app gets for testing its own work's progress
class TestingTest < Minitest::Test
  include TaskProgress::Assertions

  def test_a_tree_outlines_as_plain_hashes
    root = TaskProgress.new("Import")
    rows = root.subtask("Rows", total: 10)
    4.times { rows.tick! }
    rows.fail!(RuntimeError.new("row 5"))
    root.done!
    assert_equal({name: "Import", status: :done, percent: 100, children: [
      {name: "Rows", status: :failed, percent: 40, count: 4, total: 10, error: "RuntimeError: row 5"}
    ]}, root.outline)
  end

  def test_a_recording_keeps_what_was_said_and_done
    recording = TaskProgress::RecordingOutput.new
    root = TaskProgress.new("Import", outputs: [recording])
    root.puts("Skipped 3 rows")
    root.subtask("Rows").done!
    assert_equal ["Skipped 3 rows"], recording.said
    assert_equal 1, recording.events(:done).length
    assert_equal "Rows", recording.outline[:children].first[:name]
  end

  def test_the_assertions_pass_and_fail_with_the_tree_in_view
    root = TaskProgress.new("Import")
    rows = root.subtask("Rows")
    rows.fail!("row 12 is broken")
    assert_task_failed rows, with: /row 12/
    error = assert_raises(Minitest::Assertion) { assert_task_done root }
    assert_includes error.message, "Expected 'Import' to be done, but it is active"
    assert_includes error.message, %(error: "RuntimeError: row 12 is broken"), "the tree comes with it"
    root.cancel!
    assert_task_canceled root
  end
end
