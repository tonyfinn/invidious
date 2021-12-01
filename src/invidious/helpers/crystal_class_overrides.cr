# Override of the TCPSocket and HTTP::Client classes in order to allow an
# IP family to be selected for domains that resolve to both IPv4 and
# IPv6 addresses.
#
class TCPSocket
  def initialize(host : String, port, dns_timeout = nil, connect_timeout = nil, family = Socket::Family::UNSPEC)
    Addrinfo.tcp(host, port, timeout: dns_timeout, family: family) do |addrinfo|
      super(addrinfo.family, addrinfo.type, addrinfo.protocol)
      connect(addrinfo, timeout: connect_timeout) do |error|
        close
        error
      end
    end
  end
end

# :ditto:
class HTTP::Client
  property family : Socket::Family = Socket::Family::UNSPEC

  private def io
    io = @io
    return io if io
    unless @reconnect
      raise "This HTTP::Client cannot be reconnected"
    end

    hostname = @host.starts_with?('[') && @host.ends_with?(']') ? @host[1..-2] : @host
    io = TCPSocket.new hostname, @port, @dns_timeout, @connect_timeout, @family
    io.read_timeout = @read_timeout if @read_timeout
    io.write_timeout = @write_timeout if @write_timeout
    io.sync = false

    {% if !flag?(:without_openssl) %}
      if tls = @tls
        tcp_socket = io
        begin
          io = OpenSSL::SSL::Socket::Client.new(tcp_socket, context: tls, sync_close: true, hostname: @host)
        rescue exc
          # don't leak the TCP socket when the SSL connection failed
          tcp_socket.close
          raise exc
        end
      end
    {% end %}

    @io = io
  end
end

# Mute the ClientError exception raised when a
# connection is unexpectedly closed by the client.
#
class HTTP::Server::Response
  class Output
    # Copy-paste of https://github.com/crystal-lang/crystal/blob/1.2.2/src/http/server/response.cr#L205-L228
    # but without the "raise" statement in `rescue ex`
    private def unbuffered_write(slice : Bytes)
      return if slice.empty?

      unless response.wrote_headers?
        if response.version != "HTTP/1.0" && !response.headers.has_key?("Content-Length")
          response.headers["Transfer-Encoding"] = "chunked"
          @chunked = true
        end
      end

      ensure_headers_written

      if @chunked
        slice.size.to_s(@io, 16)
        @io << "\r\n"
        @io.write(slice)
        @io << "\r\n"
      else
        @io.write(slice)
      end
    rescue ex : IO::Error
      unbuffered_close
    end

    # Copy-paste of https://github.com/crystal-lang/crystal/blob/1.2.2/src/http/server/response.cr#L274-L280
    # but without the "raise" statement in `rescue ex`
    private def unbuffered_flush
      @io.flush
    rescue ex : IO::Error
      unbuffered_close
    end
  end
end

# TODO: Document this override
#
class PG::ResultSet
  def field(index = @column_index)
    @fields.not_nil![index]
  end
end
