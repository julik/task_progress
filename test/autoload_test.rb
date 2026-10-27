require_relative "test_helper"
require "open3"
require "rbconfig"

class AutoloadTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  # A fresh interpreter without RubyGems or Bundler (which `bundle exec` puts in RUBYOPT), so
  # nothing but the gem itself can pull json or openssl in
  def ruby(script)
    out, status = Open3.capture2e({"RUBYOPT" => nil}, RbConfig.ruby, "--disable-gems", "-W0", "-I", LIB, "-e", script)
    assert status.success?, out
    out
  end

  def test_requiring_the_gem_loads_only_its_entry_file
    out = ruby(<<~RUBY)
      before = $LOADED_FEATURES.dup
      require "task_progress"
      p $LOADED_FEATURES - before
      p [defined?(JSON), defined?(OpenSSL), defined?(SecureRandom)]
    RUBY
    loaded, defined = out.lines.map { eval(it) } # rubocop:disable Security/Eval
    assert_equal ["task_progress.rb"], loaded.map { File.basename(it) }
    assert_equal [nil, nil, nil], defined
  end

  def test_a_tree_in_memory_needs_neither_json_nor_openssl
    out = ruby(<<~RUBY)
      require "task_progress"
      TaskProgress.new("x").subtask("y") { it.tick! }
      p [defined?(JSON), defined?(OpenSSL)]
    RUBY
    assert_equal "[nil, nil]\n", out
  end

  def test_the_heavy_parts_load_with_the_classes_that_use_them
    out = ruby(<<~RUBY)
      require "task_progress"
      TaskProgress::CancelToken
      p [defined?(OpenSSL), defined?(JSON)]
      TaskProgress::Wire
      p defined?(JSON)
    RUBY
    assert_equal %(["constant", nil]\n"constant"\n), out
  end

  # A misspelled autoload path would otherwise only show when someone first uses that class.
  # Each constant loads in a process of its own, so one that leans on another at load time
  # without going through its autoload shows up as well
  def test_every_constant_resolves_on_its_own
    skip "needs fork" unless Process.respond_to?(:fork)
    out = ruby(<<~RUBY)
      require "task_progress"
      TaskProgress.constants.sort.each do |name|
        pid = fork do
          TaskProgress.const_get(name)
          exit!(0)
        rescue LoadError => e
          exit!(name == :TrackedIO && e.message.include?("progressive_io") ? 0 : 1)
        rescue Exception => e
          warn "\#{name}: \#{e.class}: \#{e.message}"
          exit!(1)
        end
        Process.wait(pid)
        puts "\#{name} \#{$?.success? ? "ok" : "failed"}"
      end
    RUBY
    names = out.lines.grep(/ (ok|failed)$/).map { it.split.first.to_sym }
    expected = %i[VERSION Event OPS Batch State Node Journal Wire Log Transaction Branch Mount Squasher
      SummaryOutput NDJSONOutput PublishingOutput BufferedOutput RactorOutput TerminalOutput ExecutionLogOutput
      SSE Refinements CancelToken TrackedIO RACTORS Canceled]
    assert_empty expected - names, out
    refute_match(/failed/, out)
  end

  def test_eager_load_loads_every_part
    out = ruby(<<~RUBY)
      require "task_progress"
      TaskProgress.eager_load!
      p TaskProgress.constants.select { TaskProgress.autoload?(it) }
      p [defined?(JSON), defined?(OpenSSL)]
    RUBY
    assert_equal %([:TrackedIO]\n["constant", "constant"]\n), out, "TrackedIO stays unloaded without progressive_io"
  end
end
