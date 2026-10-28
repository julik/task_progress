# frozen_string_literal: true
# rbs_inline: enabled

require "openssl"

class TaskProgress
  # The right to see a tree and to ask for its tasks to be canceled, signed, and good for a while.
  # The server issues one when it hands out a page - after it has decided the page may show that
  # tree - and checks it when the page comes back for the tree or with a cancellation. So neither
  # can be forged without the secret, or used after the token expires, and the tree's own key never
  # has to reach a page. Which tasks may be canceled is for `cancelable` to say.
  #
  #     tokens = TaskProgress::Token.new(ENV.fetch("TASK_PROGRESS_SECRET"))
  #     token = tokens.issue(import.key, expires_in: 3600)  # into the page
  #     tokens.verify(token)                                # => import.key, when the page comes back
  class Token
    # @rbs @secret: String
    # @rbs @clock: ^() -> Integer

    # Signs with `secret`, which must be at least 32 bytes
    #: (String, ?clock: ^() -> Integer) -> void
    def initialize(secret, clock: -> { Time.now.to_i })
      raise ArgumentError, "The secret must be at least 32 bytes" if secret.to_s.bytesize < 32
      @secret = secret.to_s
      @clock = clock
    end

    # A token for `subject` - a log id, a run, whatever the tokens are checked against - good for `expires_in` seconds
    #: (String, ?expires_in: Integer) -> String
    def issue(subject, expires_in: 3600)
      payload = encode("#{subject}\n#{@clock.call + expires_in}")
      "#{payload}.#{sign(payload)}"
    end

    # What the token was issued for, or nil if it is forged, mangled or expired
    #: (String?) -> String?
    def verify(token)
      payload, signature = token.to_s.split(".", 2)
      return unless payload && signature && signature.bytesize == sign(payload).bytesize
      return unless OpenSSL.fixed_length_secure_compare(signature, sign(payload))
      subject, expires = decode(payload).split("\n", 2)
      subject if expires && Integer(expires, exception: false)&.>=(@clock.call)
    rescue ArgumentError
      nil
    end

    private

    #: (String) -> String
    def sign(payload) = encode(OpenSSL::HMAC.digest("SHA256", @secret, "task_progress.token\n#{payload}"))

    #: (String) -> String
    def encode(bytes) = [bytes].pack("m0").tr("+/", "-_").delete("=")

    #: (String) -> String
    def decode(text) = (text + "=" * (-text.length % 4)).tr("-_", "+/").unpack1("m0").to_s.force_encoding(Encoding::UTF_8)
  end
end
