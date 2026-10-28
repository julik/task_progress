require_relative "test_helper"
require "json"
require "open3"
require "tmpdir"

class VendorTest < Minitest::Test
  def test_the_client_is_copied_as_a_package_of_its_own
    Dir.mktmpdir do |dir|
      to = File.join(dir, "vendor", "task_progress")
      files = TaskProgress.vendor_js(to)
      assert_includes files, "react_task_tree.js"
      assert_includes files, "react_task_tree.d.ts"
      assert_includes files, "task_tree.css"
      assert_equal files, Dir.children(to).sort
      assert_equal TaskProgress::VERSION, TaskProgress.vendored_js_version(to)
      assert_equal "task_progress", JSON.parse(File.read(File.join(to, "package.json")))["name"]
    end
  end

  def test_vendoring_again_replaces_what_was_there
    Dir.mktmpdir do |dir|
      TaskProgress.vendor_js(dir)
      File.write(File.join(dir, "shipped_once.js"), "")
      File.write(File.join(dir, "task_tree.js"), "edited")
      TaskProgress.vendor_js(dir)
      refute File.exist?(File.join(dir, "shipped_once.js"))
      assert_equal File.read(File.join(TaskProgress.js_path, "task_tree.js")), File.read(File.join(dir, "task_tree.js"))
    end
  end

  def test_a_directory_of_someone_elses_is_left_alone
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "application.js"), "mine")
      assert_raises(ArgumentError) { TaskProgress.vendor_js(dir) }
      File.write(File.join(dir, "package.json"), JSON.generate({name: "my-app"}))
      assert_raises(ArgumentError) { TaskProgress.vendor_js(dir) }
      File.write(File.join(dir, "package.json"), "{nope")
      assert_raises(ArgumentError) { TaskProgress.vendor_js(dir) }
      assert_equal "mine", File.read(File.join(dir, "application.js"))
    end
  end

  def test_nothing_vendored_has_no_version
    Dir.mktmpdir { assert_nil TaskProgress.vendored_js_version(it) }
  end

  def test_the_command_vendors_into_the_current_directory
    exe = File.expand_path("../exe/task_progress", __dir__)
    Dir.mktmpdir do |dir|
      out, status = Open3.capture2e(RbConfig.ruby, exe, "vendor", chdir: dir)
      assert status.success?, out
      assert File.exist?(File.join(dir, "task_progress", "task_tree.js")), out
      # In a Rails app, where the Railtie looks for it
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "")
      out, status = Open3.capture2e(RbConfig.ruby, exe, "vendor", chdir: dir)
      assert status.success?, out
      assert File.exist?(File.join(dir, "vendor", "javascript", "task_progress", "task_tree.js")), out
    end
  end
end
