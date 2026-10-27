# The code is checked against the types written next to it, as RBS comments - `rake types`
# writes them out to sig/generated, and Steep reads them from there
D = Steep::Diagnostic

target :lib do
  signature "sig"
  check "lib"

  library "json", "openssl", "securerandom", "io-console"

  configure_code_diagnostics(D::Ruby.default)
end
