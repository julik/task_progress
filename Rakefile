require "bundler/gem_tasks"
require "rake/testtask"
require "standard/rake"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

task default: %i[test standard types]

desc "Write the inline RBS types out to sig/generated"
task :rbs do
  rm_rf "sig/generated"
  sh "bundle exec rbs-inline --output=sig/generated lib"
end

desc "Check the code against its types with Steep"
task types: :rbs do
  sh "bundle exec steep check"
end

desc "Build the API docs into doc/ - Markdown, with the types as signatures"
task :doc do
  rm_rf "doc"
  sh "bundle exec rdoc --output doc lib README.md MANUAL.md RECIPES.md"
  cp_r "docs", "doc/docs" # the screenshots the README shows
end

desc "Build the API docs and open them in a browser"
task "doc:open" => :doc do
  page = File.expand_path("doc/index.html", __dir__)
  opener = RUBY_PLATFORM.include?("darwin") ? "open" : "xdg-open"
  system(opener, page) or puts "Open #{page} in a browser"
end

desc "Fail unless every public class, method and constant is documented"
task "doc:check" do
  report = `bundle exec rdoc -C lib 2>&1`
  abort report[/The following items are not documented:.*/m] unless report.include?("100.00% documented")
  puts report[/\d+\.\d+% documented/]
end
