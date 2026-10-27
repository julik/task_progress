source "https://rubygems.org"

gemspec

# Optional at runtime: TaskProgress#track_io loads it when first called
gem "progressive_io", "~> 2.0"

group :examples do
  # From main until a release has the fix for ?s=00000000 after an edit, which bin/dev hits all the time
  gem "assiette", github: "julik/assiette"
  gem "puma"
  gem "rackup"
end

group :development do
  # Types live inline, as RBS comments next to the code; rbs-inline writes them out to sig/, and
  # Steep checks the code against them
  gem "rbs-inline", require: false
  gem "steep", require: false
  gem "rdoc", require: false
end

group :test do
  # The browser tests drive the bench in a headless Chrome; without one they skip
  gem "ferrum", "~> 0.17"
  # A small Rails app, booted in a process of its own, for the Railtie, the helper and the Turbo
  # broadcasts - the gem itself never needs Rails
  gem "railties", require: false
  gem "actioncable", require: false
  gem "activemodel", require: false
  gem "turbo-rails", require: false
  gem "activejob", require: false
  # The Redis stream is tested against a real Redis, through both clients it takes, when one runs
  gem "redis-client", require: false
  gem "redis", require: false
end
