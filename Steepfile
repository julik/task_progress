# The code is checked against the types written next to it, as RBS comments - `rake types`
# writes them out to sig/generated, and Steep reads them from there
D = Steep::Diagnostic

target :lib do
  signature "sig"
  check "lib"
  # Rails is not a dependency, so there are no types for it to check the Railtie against
  ignore "lib/task_progress/railtie.rb", "lib/task_progress/job_serializer.rb"

  library "json", "openssl", "securerandom", "io-console", "cgi", "uri", "erb", "pp", "digest"

  configure_code_diagnostics(D::Ruby.default)
end
