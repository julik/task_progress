# frozen_string_literal: true
# rbs_inline: enabled

require "openssl"

class TaskProgress
  # Lets whoever was shown a tree cancel tasks in it, and nobody else. The server issues a token
  # for a log when it hands out the page or the stream, and checks it when a cancellation comes
  # back - so a cancel cannot be forged without the secret, or replayed after the token expires.
  # It says nothing about which task: that is for `cancelable` to say.
  #
  #     tokens = TaskProgress::CancelToken.new(ENV.fetch("TASK_PROGRESS_SECRET"))
  #     token = tokens.issue(root.log.id, expires_in: 3600)  # into the page, next to the stream URL
  #     tokens.verify(params[:token]) == root.log.id         # when the cancellation comes in
  class CancelToken
    # @rbs @secret: String
    # @rbs @clock: ^() -> Integer

    # Signs with `secret`, which must be at least 32 bytes
    #: (String, ?clock: ^() -> Integer) -> void
    def initialize(secret, clock: -> { Time.now.to_i })
      raise ArgumentError, "The secret must be at least 32 bytes" if secret.to_s.bytesize < 32
      @secret = secret.to_s
      @clock = clock
    end

    # A token for the log `log_id`, good for `expires_in` seconds
    #: (String, ?expires_in: Integer) -> String
    def issue(log_id, expires_in: 3600)
      payload = encode("#{log_id}\n#{@clock.call + expires_in}")
      "#{payload}.#{sign(payload)}"
    end

    # The log id the token was issued for, or nil if it is forged, mangled or expired
    #: (String?) -> String?
    def verify(token)
      payload, signature = token.to_s.split(".", 2)
      return unless payload && signature && signature.bytesize == sign(payload).bytesize
      return unless OpenSSL.fixed_length_secure_compare(signature, sign(payload))
      log_id, expires = decode(payload).split("\n", 2)
      log_id if expires && Integer(expires, exception: false)&.>=(@clock.call)
    rescue ArgumentError
      nil
    end

    private

    #: (String) -> String
    def sign(payload) = encode(OpenSSL::HMAC.digest("SHA256", @secret, "task_progress.cancel\n#{payload}"))

    #: (String) -> String
    def encode(bytes) = [bytes].pack("m0").tr("+/", "-_").delete("=")

    #: (String) -> String
    def decode(text) = (text + "=" * (-text.length % 4)).tr("-_", "+/").unpack1("m0").to_s.force_encoding(Encoding::UTF_8)
  end
end
