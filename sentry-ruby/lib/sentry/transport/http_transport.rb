# frozen_string_literal: true

require "net/http"
require "zlib"

module Sentry
  class HTTPTransport < Transport
    GZIP_ENCODING = "gzip"
    GZIP_THRESHOLD = 1024 * 30
    CONTENT_TYPE = 'application/x-sentry-envelope'

    DEFAULT_DELAY = 60
    RETRY_AFTER_HEADER = "retry-after"
    RATE_LIMIT_HEADER = "x-sentry-rate-limits"
    USER_AGENT = "sentry-ruby/#{Sentry::VERSION}"

    attr_reader :conn

    def initialize(*args)
      super
      @conn = set_conn
      @endpoint = @dsn.envelope_endpoint
    end

    def send_data(data)
      encoding = ""

      if should_compress?(data)
        data = Zlib.gzip(data)
        encoding = GZIP_ENCODING
      end

      headers = {
        'Content-Type' => CONTENT_TYPE,
        'Content-Encoding' => encoding,
        'X-Sentry-Auth' => generate_auth_header,
        'User-Agent' => USER_AGENT
      }

      response = conn.start do |http|
        request = ::Net::HTTP::Post.new(@endpoint, headers)
        request.body = data
        http.request(request)
      end

      if response.code.match?(/\A2\d{2}/)
        if has_rate_limited_header?(response)
          handle_rate_limited_response(response)
        end
      else
        error_info = "the server responded with status #{response.code}"

        if response.code == "429"
          handle_rate_limited_response(response)
        else
          error_info += "\nbody: #{response.body}"
          error_info += " Error in headers is: #{response['x-sentry-error']}" if response['x-sentry-error']
        end

        raise Sentry::ExternalError, error_info
      end
    rescue SocketError => e
      raise Sentry::ExternalError.new(e.message)
    end

    private

    def has_rate_limited_header?(headers)
      headers[RETRY_AFTER_HEADER] || headers[RATE_LIMIT_HEADER]
    end

    def handle_rate_limited_response(headers)
      rate_limits =
        if rate_limits = headers[RATE_LIMIT_HEADER]
          parse_rate_limit_header(rate_limits)
        elsif retry_after = headers[RETRY_AFTER_HEADER]
          # although Sentry doesn't send a date string back
          # based on HTTP specification, this could be a date string (instead of an integer)
          retry_after = retry_after.to_i
          retry_after = DEFAULT_DELAY if retry_after == 0

          { nil => Time.now + retry_after }
        else
          { nil => Time.now + DEFAULT_DELAY }
        end

      rate_limits.each do |category, limit|
        if current_limit = @rate_limits[category]
          if current_limit < limit
            @rate_limits[category] = limit
          end
        else
          @rate_limits[category] = limit
        end
      end
    end

    def parse_rate_limit_header(rate_limit_header)
      time = Time.now

      result = {}

      limits = rate_limit_header.split(",")
      limits.each do |limit|
        next if limit.nil? || limit.empty?

        begin
          retry_after, categories = limit.strip.split(":").first(2)
          retry_after = time + retry_after.to_i
          categories = categories.split(";")

          if categories.empty?
            result[nil] = retry_after
          else
            categories.each do |category|
              result[category] = retry_after
            end
          end
        rescue StandardError
        end
      end

      result
    end

    def should_compress?(data)
      @transport_configuration.encoding == GZIP_ENCODING && data.bytesize >= GZIP_THRESHOLD
    end

    def set_conn
      server = URI(@dsn.server)

      log_debug("Sentry HTTP Transport connecting to #{server}")

      use_ssl = server.scheme == "https"
      port = use_ssl ? 443 : 80

      connection =
        if proxy = @transport_configuration.proxy
          ::Net::HTTP.new(server.hostname, port, proxy[:uri].hostname, proxy[:uri].port, proxy[:user], proxy[:password])
        else
          ::Net::HTTP.new(server.hostname, port, nil)
        end

      connection.use_ssl = use_ssl
      connection.read_timeout = @transport_configuration.timeout
      connection.write_timeout = @transport_configuration.timeout if connection.respond_to?(:write_timeout)
      connection.open_timeout = @transport_configuration.open_timeout

      ssl_configuration.each do |key, value|
        connection.send("#{key}=", value)
      end

      connection
    end

    def ssl_configuration
      configuration = {
        verify: @transport_configuration.ssl_verification,
        ca_file: @transport_configuration.ssl_ca_file
      }.merge(@transport_configuration.ssl || {})

      configuration[:verify_mode] = configuration.delete(:verify) ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
      configuration
    end
  end
end
