require_relative "test_helper"
require "tmpdir"

# A task with thousands of children draws as a handful of rows - the same ones in Ruby and in
# the browser client
class FoldTest < Minitest::Test
  include TestHelpers

  def big_tree
    root = TaskProgress.new("Thumbnails", log: ticking_log)
    files = root.subtask("Files", expect: 1000)
    tasks = 1000.times.map { files.subtask("file #{it}") }
    tasks.first(900).each(&:done!)
    tasks[900].fail!("unreadable")
    tasks[901..903].each { it.note("resizing") }
    root
  end

  def test_done_and_waiting_siblings_fold_into_a_row_each
    rows = big_tree.log.snapshot.rows.map { |path, node| [path.length, node.name] }
    assert_equal ["Thumbnails", "Files", "897 more done", "file 897", "file 898", "file 899", "file 900", "file 901", "file 902", "file 903",
      "file 904", "file 905", "file 906", "93 more waiting"], rows.map(&:last)
    assert_equal [0, 1, 2, 2], rows.first(4).map(&:first), "folds sit at their siblings' depth"
  end

  def test_a_small_family_is_never_folded
    root = TaskProgress.new("Small")
    5.times { root.subtask("t#{it}").done! }
    assert_equal root.log.snapshot.each.count, root.log.snapshot.rows.count
  end

  def test_the_renderers_draw_folds
    root = big_tree
    html = TaskProgress::HTMLRenderer.new(id: "tree").render(root.log.snapshot)
    assert_equal 14, html.scan('<div class="row').length
    assert_includes html, '<span class="name">897 more done</span>'
    assert_includes html, 'class="row folded pending"'

    io = StringIO.new
    TaskProgress::TerminalOutput.new(io)
    lines = TaskProgress::TerminalOutput.new(io).lines(root.log.snapshot, width: 80, height: 40)
    assert_includes lines, "    ✓ 897 more done"
    assert_includes lines, "    · 93 more waiting"
  end

  def test_the_browser_client_folds_the_same_way
    root = big_tree
    file = File.join(Dir.mktmpdir, "tree.ndjson")
    File.write(file, TaskProgress::Wire.dump(root.log.squashed) + "\n")
    script = <<~JS
      import { readFileSync } from "node:fs"
      import { TaskTree } from "#{File.expand_path("../js/task_tree.js", __dir__)}"
      import { rowView } from "#{File.expand_path("../js/row_view.js", __dir__)}"
      const tree = new TaskTree()
      tree.apply(JSON.parse(readFileSync(process.argv[1], "utf8")))
      console.log(JSON.stringify([...tree.rows()].map((node) => rowView(tree, node).name)))
    JS
    out = IO.popen(["node", "--input-type=module", "-e", script, file], &:read)
    assert $?.success?, out
    ruby = root.log.snapshot.rows.map { |_, node| node.name }
    assert_equal ruby, JSON.parse(out)
  rescue Errno::ENOENT
    skip "there is no node"
  end
end
