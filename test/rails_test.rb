require_relative "test_helper"
require "open3"

# The Rails side - the Railtie, the helper, broadcasting through Action Cable, the cancel route -
# checked in an app booted in a process of its own (test/rails/app_check.rb). Skipped without the
# Rails gems, which the gem itself never needs
class RailsTest < Minitest::Test
  def test_a_rails_app_gets_the_helper_the_broadcasts_and_the_cancel_route
    skip "railties and turbo-rails are not installed" unless Gem.loaded_specs.key?("turbo-rails")
    out, status = Open3.capture2e(RbConfig.ruby, File.expand_path("rails/app_check.rb", __dir__))
    assert status.success?, out
    assert_match(/15 runs, \d+ assertions, 0 failures, 0 errors/, out)
  end
end
