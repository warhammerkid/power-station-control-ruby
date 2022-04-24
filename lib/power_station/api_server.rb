require 'webrick'
require 'json'
require 'base64'

module PowerStation
  class ApiServer
    def initialize(event_bus, port)
      @event_bus = event_bus
      @port = port
    end

    def start
      $logger.info "Starting api server on port #{@port}"
      @thread = Thread.new { server.start }
      @thread.abort_on_exception = true

      self
    end

    def stop
      $logger.info 'Stopping api server...'
      server.shutdown
      $logger.info 'Api server stopped'
    end

    private

    def server
      return @server if defined?(@server)

      @server = WEBrick::HTTPServer.new(
        BindAddress: '0.0.0.0',
        Port: @port,
        Logger: $logger,
        AccessLog: []
      )

      @server.mount_proc '/' do |req, res|
        res.status = 404
        res['Content-Type'] = 'text/plain; charset=utf-8'
        res.body = 'Not Found'
      end

      @server
    end
  end
end
