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
