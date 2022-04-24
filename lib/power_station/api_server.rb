require 'webrick'
require 'json'
require 'base64'

module PowerStation
  class ApiServer
    def initialize(mqtt_server, port)
      @mqtt_server = mqtt_server
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
        if req.path == '/api/v1/dump_memory'
          handle_dump_memory(req, res)
        elsif req.request_method == 'POST' && req.path == '/api/v1/update'
          handle_update(req, res)
        else
          res.status = 404
          res['Content-Type'] = 'text/plain; charset=utf-8'
          res.body = 'Not Found'
        end
      end

      @server
    end

    def handle_dump_memory(req, res)
      # Is the requested client connected?
      client = lookup_client(req.query['serial_number'])
      if client.nil?
        res.status = 404
        res['Content-Type'] = 'application/json; charset=utf-8'
        res.body = '{"error":"Client Not Connected"}'
        return
      end

      # Look up page
      page =
        case req.query['page'].to_i
        when MqttClient::STATUS_PAGE_ID
          client.status_page
        when MqttClient::CONTROL_PAGE_ID
          client.control_page
        when MqttClient::WIFI_PAGE_ID
          client.wifi_page
        else
          res.status = 404
          res['Content-Type'] = 'application/json; charset=utf-8'
          res.body = '{"error":"Unknown Page Type"}'
          return
        end

      # Build response
      res.status = 200
      res['Content-Type'] = 'application/json; charset=utf-8'
      res.body = {
        page: req.query['page'].to_i,
        serial_number: client.serial_number,
        data: Base64.strict_encode64(page.raw)
      }.to_json
    end

    def handle_update(req, res)
      req_json = JSON.parse(req.body)

      # Is the requested client connected?
      client = lookup_client(req_json['serial_number'])
      if client.nil?
        res.status = 404
        res['Content-Type'] = 'text/plain; charset=utf-8'
        res.body = 'Client Not Connected'
        return
      end

      # Make request
      data = Base64.strict_decode64(req_json['data'])
      client.make_request(req_json['page'], req_json['offset'], data)

      # Build response
      res.status = 200
      res['Content-Type'] = 'text/plain; charset=utf-8'
      res.body = 'Request Sent'
    end

    def lookup_client(serial_number)
      @mqtt_server.clients.reverse.find { _1.serial_number == serial_number }
    end
  end
end
