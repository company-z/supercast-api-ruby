# frozen_string_literal: true

module Supercast
  # Client executes requests against the Supercast API and allows a user to
  # recover both a resource a call returns as well as a response object that
  # contains information on the HTTP call.
  class Client
    attr_accessor :conn

    # Initializes a new Client. Expects a Faraday connection object, and
    # uses a default connection unless one is passed.
    def initialize(conn = nil)
      self.conn = conn || self.class.default_conn
      @system_profiler = SystemProfiler.new
    end

    def self.active_client
      Thread.current[:supercast_client] || default_client
    end

    def self.default_client
      Thread.current[:supercast_client_default_client] ||=
        Client.new(default_conn)
    end

    # A default Faraday connection to be used when one isn't configured. This
    # object should never be mutated, and instead instantiating your own
    # connection and wrapping it in a Client object should be preferred.
    def self.default_conn
      # We're going to keep connections around so that we can take advantage
      # of connection re-use, so make sure that we have a separate connection
      # object per thread.
      Thread.current[:supercast_client_default_conn] ||= begin
        conn = Faraday.new do |builder|
          builder.use Faraday::Request::Multipart
          builder.use Faraday::Request::UrlEncoded
          builder.use Faraday::Response::RaiseError

          # Net::HTTP::Persistent doesn't seem to do well on Windows or JRuby,
          # so fall back to default there.
          if Gem.win_platform? || RUBY_PLATFORM == 'java'
            builder.adapter :net_http
          else
            builder.adapter :net_http_persistent
          end
        end

        conn.proxy = Supercast.proxy if Supercast.proxy

        if Supercast.verify_ssl_certs
          conn.ssl.verify = true
          conn.ssl.cert_store = Supercast.ca_store
        else
          conn.ssl.verify = false

          unless @verify_ssl_warned
            @verify_ssl_warned = true

            warn('WARNING: Running without SSL cert verification. ' \
              'You should never do this in production. ' \
              'Execute `Supercast.verify_ssl_certs = true` to enable ' \
              'verification.')
          end
        end

        conn
      end
    end

    # Checks if an error is a problem that we should retry on. This includes
    # both socket errors that may represent an intermittent problem and some
    # special HTTP statuses.
    def self.should_retry?(error, num_retries)
      return false if num_retries >= Supercast.max_network_retries

      # Retry on timeout-related problems (either on open or read).
      return true if error.is_a?(Faraday::TimeoutError)

      # Destination refused the connection, the connection was reset, or a
      # variety of other connection failures. This could occur from a single
      # saturated server, so retry in case it's intermittent.
      return true if error.is_a?(Faraday::ConnectionFailed)

      false
    end

    def self.sleep_time(num_retries)
      # Apply exponential backoff with initial_network_retry_delay on the
      # number of num_retries so far as inputs. Do not allow the number to
      # exceed max_network_retry_delay.
      sleep_seconds = [
        Supercast.initial_network_retry_delay * (2**(num_retries - 1)),
        Supercast.max_network_retry_delay
      ].min

      # Apply some jitter by randomizing the value in the range of
      # (sleep_seconds / 2) to (sleep_seconds).
      sleep_seconds *= (0.5 * (1 + rand))

      # But never sleep less than the base sleep seconds.
      sleep_seconds = [Supercast.initial_network_retry_delay, sleep_seconds].max

      sleep_seconds
    end

    # Executes the API call within the given block. Usage looks like:
    #
    #     client = Client.new
    #     charge, resp = client.request { Episode.create }
    #
    def request
      @last_response = nil
      old_supercast_client = Thread.current[:supercast_client]
      Thread.current[:supercast_client] = self

      begin
        res = yield
        [res, @last_response]
      ensure
        Thread.current[:supercast_client] = old_supercast_client
      end
    end

    def execute_request(method, path, api_base: nil, api_version: nil, api_key: nil, headers: {}, params: {}) # rubocop:disable Metrics/AbcSize Metrics/MethodLength
      api_base ||= Supercast.api_base
      api_version ||= Supercast.api_version
      api_key ||= Supercast.api_key
      params = Util.objects_to_ids(params)

      check_api_key!(api_key)

      body = nil
      query_params = nil
      case method.to_s.downcase.to_sym
      when :get, :head, :delete
        query_params = params
      else
        body = params
      end

      # This works around an edge case where we end up with both query
      # parameters in `query_params` and query parameters that are appended
      # onto the end of the given path. In this case, Faraday will silently
      # discard the URL's parameters which may break a request.
      #
      # Here we decode any parameters that were added onto the end of a path
      # and add them to `query_params` so that all parameters end up in one
      # place and all of them are correctly included in the final request.
      u = URI.parse(path)
      unless u.query.nil?
        query_params ||= {}
        query_params = Hash[URI.decode_www_form(u.query)].merge(query_params)

        # Reset the path minus any query parameters that were specified.
        path = u.path
      end

      headers = request_headers(api_key, method).update(Util.normalize_headers(headers))
      params_encoder = FaradaySupercastEncoder.new
      url = api_url(path, api_base, api_version)

      # stores information on the request we're about to make so that we don't
      # have to pass as many parameters around for logging.
      context = RequestLogContext.new
      context.account         = headers['Supercast-Account']
      context.api_key         = api_key
      context.api_version     = headers['Supercast-Version']
      context.body            = body ? params_encoder.encode(body) : nil
      context.method          = method
      context.path            = path
      context.query_params    = (params_encoder.encode(query_params) if query_params)

      # note that both request body and query params will be passed through
      # `FaradaySupercastEncoder`
      http_resp = execute_request_with_rescues(api_base, context) do
        conn.run_request(method, url, body, headers) do |req|
          req.options.open_timeout = Supercast.open_timeout
          req.options.params_encoder = params_encoder
          req.options.timeout = Supercast.read_timeout
          req.params = query_params unless query_params.nil?
        end
      end

      begin
        resp = Response.from_faraday_response(http_resp)
      rescue JSON::ParserError
        raise general_api_error(http_resp.status, http_resp.body)
      end

      # Allows Client#request to return a response object to a caller.
      @last_response = resp
      [resp, api_key]
    end

    # Used to workaround buggy behavior in Faraday: the library will try to
    # reshape anything that we pass to `req.params` with one of its default
    # encoders. I don't think this process is supposed to be lossy, but it is
    # -- in particular when we send our integer-indexed maps (i.e. arrays),
    # Faraday ends up stripping out the integer indexes.
    #
    # We work around the problem by implementing our own simplified encoder and
    # telling Faraday to use that.
    #
    # The class also performs simple caching so that we don't have to encode
    # parameters twice for every request (once to build the request and once
    # for logging).
    #
    # When initialized with `multipart: true`, the encoder just inspects the
    # hash instead to get a decent representation for logging. In the case of a
    # multipart request, Faraday won't use the result of this encoder.
    class FaradaySupercastEncoder
      def initialize
        @cache = {}
      end

      # This is quite subtle, but for a `multipart/form-data` request Faraday
      # will throw away the result of this encoder and build its body.
      def encode(hash)
        @cache.fetch(hash) do |k|
          @cache[k] = Util.encode_parameters(hash)
        end
      end

      # We should never need to do this so it's not implemented.
      def decode(_str)
        raise NotImplementedError,
              "#{self.class.name} does not implement #decode"
      end
    end

    private

    def api_url(url = '', api_base = nil, api_version = nil)
      "#{api_base || Supercast.api_base}/#{api_version}#{url}"
    end

    def check_api_key!(api_key)
      unless api_key
        raise AuthenticationError, 'No API key provided. ' \
          'Set your API key using "Supercast.api_key = <API-KEY>". ' \
          'You can generate API keys from the Supercast web interface. ' \
          'See https://docs.supercast.tech/docs/access-tokens for details, or email ' \
          'support@supercast.com if you have any questions.'
      end

      return unless api_key =~ /\s/

      raise AuthenticationError, 'Your API key is invalid, as it contains ' \
        'whitespace. (HINT: You can double-check your API key from the ' \
        'Supercast web interface. See https://docs.supercast.tech/docs/access-tokens for details, or ' \
        'email support@supercast.com if you have any questions.)'
    end

    def execute_request_with_rescues(api_base, context)
      num_retries = 0
      begin
        request_start = Time.now
        log_request(context, num_retries)
        resp = yield
        context = context.dup_from_response(resp)
        log_response(context, request_start, resp.status, resp.body)

      # We rescue all exceptions from a request so that we have an easy spot to
      # implement our retry logic across the board. We'll re-raise if it's a
      # type of exception that we didn't expect to handle.
      rescue StandardError => e
        # If we modify context we copy it into a new variable so as not to
        # taint the original on a retry.
        error_context = context

        if e.respond_to?(:response) && e.response
          error_context = context.dup_from_response(e.response)
          log_response(error_context, request_start,
                       e.response[:status], e.response[:body])
        else
          log_response_error(error_context, request_start, e)
        end

        if self.class.should_retry?(e, num_retries)
          num_retries += 1
          sleep self.class.sleep_time(num_retries)
          retry
        end

        case e
        when Faraday::ClientError
          if e.response
            handle_error_response(e.response, error_context)
          else
            handle_network_error(e, error_context, num_retries, api_base)
          end

        # Only handle errors when we know we can do so, and re-raise otherwise.
        # This should be pretty infrequent.
        else
          raise
        end
      end

      resp
    end

    def general_api_error(status, body)
      APIError.new("Invalid response object from API: #{body.inspect} " \
                   "(HTTP response code was #{status})",
                   http_status: status, http_body: body)
    end

    def handle_error_response(http_resp, context)
      begin
        resp = Response.from_faraday_hash(http_resp)
      rescue StandardError
        raise general_api_error(http_resp[:status], http_resp[:body])
      end

      error = specific_api_error(resp, context)

      error.response = resp
      raise(error)
    end

    def specific_api_error(resp, context)
      Util.log_error('Supercast API error',
                     status: resp.http_status,
                     error_code: resp.http_status,
                     error_message: resp.data[:message],
                     idempotency_key: context.idempotency_key)

      # The standard set of arguments that can be used to initialize most of
      # the exceptions.
      opts = {
        http_body: resp.http_body,
        http_headers: resp.http_headers,
        http_status: resp.http_status,
        json_body: resp.data,
        code: resp.http_status
      }

      case resp.http_status
      when 400, 404, 422
        InvalidRequestError.new(resp.data[:message], opts)
      when 401
        AuthenticationError.new(resp.data[:message], opts)
      when 403
        PermissionError.new(resp.data[:message], opts)
      when 429
        RateLimitError.new(resp.data[:message], opts)
      else
        APIError.new(resp.data[:message], opts)
      end
    end

    def handle_network_error(error, context, num_retries,
                             api_base = nil)
      Util.log_error('Supercast network error',
                     error_message: error.message,
                     idempotency_key: context.idempotency_key)

      case error
      when Faraday::ConnectionFailed
        message = 'Unexpected error communicating when trying to connect to ' \
          'Supercast. You may be seeing this message because your DNS is not ' \
          'working.  To check, try running `host supercast.com` from the ' \
          'command line.'

      when Faraday::SSLError
        message = 'Could not establish a secure connection to Supercast, you ' \
          'may need to upgrade your OpenSSL version. To check, try running ' \
          '`openssl s_client -connect api.supercast.com:443` from the command ' \
          'line.'

      when Faraday::TimeoutError
        api_base ||= Supercast.api_base
        message = "Could not connect to Supercast (#{api_base}). " \
          'Please check your internet connection and try again. ' \
          "If this problem persists, you should check Supercast's service " \
          'status at https://status.supercast.com, or let us know at ' \
          'support@supercast.com.'

      else
        message = 'Unexpected error communicating with Supercast. ' \
          'If this problem persists, let us know at support@supercast.com.'

      end

      message += " Request was retried #{num_retries} times." if num_retries.positive?

      raise APIConnectionError,
            message + "\n\n(Network error: #{error.message})"
    end

    def request_headers(api_key, method)
      headers = {
        'User-Agent' => "Supercast RubyBindings/#{Supercast::VERSION}",
        'Authorization' => "Bearer #{api_key}",
        'Content-Type' => 'application/x-www-form-urlencoded'
      }

      # It is only safe to retry network failures on post and delete
      # requests if we add an Idempotency-Key header
      headers['Idempotency-Key'] ||= SecureRandom.uuid if %i[post delete].include?(method) && Supercast.max_network_retries.positive?

      headers['Supercast-Version'] = Supercast.api_version if Supercast.api_version

      user_agent = @system_profiler.user_agent
      begin
        headers.update(
          'X-Supercast-Client-User-Agent' => JSON.generate(user_agent)
        )
      rescue StandardError => e
        headers.update(
          'X-Supercast-Client-Raw-User-Agent' => user_agent.inspect,
          :error => "#{e} (#{e.class})"
        )
      end

      headers
    end

    def log_request(context, num_retries)
      Util.log_info('Request to Supercast API',
                    account: context.account,
                    api_version: context.api_version,
                    idempotency_key: context.idempotency_key,
                    method: context.method,
                    num_retries: num_retries,
                    path: context.path)
      Util.log_debug('Request details',
                     body: context.body,
                     idempotency_key: context.idempotency_key,
                     query_params: context.query_params)
    end

    def log_response(context, request_start, status, body)
      Util.log_info('Response from Supercast API',
                    account: context.account,
                    api_version: context.api_version,
                    elapsed: Time.now - request_start,
                    idempotency_key: context.idempotency_key,
                    method: context.method,
                    path: context.path,
                    status: status)
      Util.log_debug('Response details',
                     body: body,
                     idempotency_key: context.idempotency_key)
    end

    def log_response_error(context, request_start, error)
      Util.log_error('Request error',
                     elapsed: Time.now - request_start,
                     error_message: error.message,
                     idempotency_key: context.idempotency_key,
                     method: context.method,
                     path: context.path)
    end

    # RequestLogContext stores information about a request that's begin made so
    # that we can log certain information. It's useful because it means that we
    # don't have to pass around as many parameters.
    class RequestLogContext
      attr_accessor :body
      attr_accessor :account
      attr_accessor :api_key
      attr_accessor :api_version
      attr_accessor :idempotency_key
      attr_accessor :method
      attr_accessor :path
      attr_accessor :query_params

      # The idea with this method is that we might want to update some of
      # context information because a response that we've received from the API
      # contains information that's more authoritative than what we started
      # with for a request. For example, we should trust whatever came back in
      # a `Supercast-Version` header beyond what configuration information that we
      # might have had available.
      def dup_from_response(resp)
        return self if resp.nil?

        # Faraday's API is a little unusual. Normally it'll produce a response
        # object with a `headers` method, but on error what it puts into
        # `e.response` is an untyped `Hash`.
        headers = if resp.is_a?(Faraday::Response)
                    resp.headers
                  else
                    resp[:headers]
                  end

        context = dup
        context.account = headers['Supercast-Account']
        context.api_version = headers['Supercast-Version']
        context.idempotency_key = headers['Idempotency-Key']
        context
      end
    end

    # SystemProfiler extracts information about the system that we're running
    # in so that we can generate a rich user agent header to help debug
    # integrations.
    class SystemProfiler
      def self.uname
        if ::File.exist?('/proc/version')
          ::File.read('/proc/version').strip
        else
          case RbConfig::CONFIG['host_os']
          when /linux|darwin|bsd|sunos|solaris|cygwin/i
            uname_from_system
          when /mswin|mingw/i
            uname_from_system_ver
          else
            'unknown platform'
          end
        end
      end

      def self.uname_from_system
        (`uname -a 2>/dev/null` || '').strip
      rescue Errno::ENOENT
        'uname executable not found'
      rescue Errno::ENOMEM # couldn't create subprocess
        'uname lookup failed'
      end

      def self.uname_from_system_ver
        (`ver` || '').strip
      rescue Errno::ENOENT
        'ver executable not found'
      rescue Errno::ENOMEM # couldn't create subprocess
        'uname lookup failed'
      end

      def initialize
        @uname = self.class.uname
      end

      def user_agent
        lang_version = "#{RUBY_VERSION} p#{RUBY_PATCHLEVEL} " \
                       "(#{RUBY_RELEASE_DATE})"

        {
          bindings_version: Supercast::VERSION,
          lang: 'ruby',
          lang_version: lang_version,
          platform: RUBY_PLATFORM,
          engine: defined?(RUBY_ENGINE) ? RUBY_ENGINE : '',
          publisher: 'supercast',
          uname: @uname,
          hostname: Socket.gethostname
        }.delete_if { |_k, v| v.nil? }
      end
    end
  end
end
