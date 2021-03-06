require 'socket'
require_relative 'mqtt_client'

class MqttServer
  PORT = 18760

  def initialize
    @mutex = Mutex.new
    @stop_read, @stop_write = IO.pipe
    @thread = nil
    @clients = []
  end

  def start
    @thread = Thread.new(&method(:run))
    @thread.abort_on_exception = true
    self
  end

  def stop
    $logger.info 'Stopping MQTT server...'
    @stop_write.write('stop')
    @thread.join
    @clients.each(&:stop)
    $logger.info 'MQTT server stopped'
  end

  def clients
    @mutex.synchronize { @clients.dup }
  end

  private

  def run
    $logger.info "Starting MQTT server on port #{PORT}..."
    server = TCPServer.new(PORT)
    loop do
      begin
        socket = server.accept_nonblock
        client = MqttClient.new(socket)
        @mutex.synchronize { @clients << client }
        client.start
      rescue IO::WaitReadable
        readable, _, __ = IO.select([server, @stop_read])
        if readable.include?(@stop_read)
          break
        else
          retry
        end
      end
    end
    server.close
  end
end
