require 'logger'
require 'socket'
require 'stringio'
require 'mqtt'

class MqttClient
  PACKET_SIZE = 1380
  TIMEOUT = 60

  def initialize(socket, server)
    @socket = socket
    @server = server
    
    @mutex = Mutex.new
    @stop_read, @stop_write = IO.pipe
    @connected = false
    @thread = nil
    @subscribes = []
  end

  def start
    @thread = Thread.new(&method(:handle))
    @thread.abort_on_exception = true
    self
  end

  def stop
    @stop_write.write('stop')
    @thread.join
  end

  def subscribes
    @mutex.synchronize { @subscribes.dup }
  end

  def connected?
    @mutex.synchronize { @connected }
  end

  def publish(packet)
    @mutex.synchronize do
      @socket.write_nonblock(packet) if @connected
    end
  end

  private

  def handle
    $logger.info "New client connected #{self.object_id}..."
    loop do
      begin
        data = @socket.read_nonblock(PACKET_SIZE)
        if data[0] == "\x00".b
          handle_mqtt_special(data)
        else
          stream = StringIO.new(data)
          while !stream.eof?
            packet = MQTT::Packet.read(stream)
            handle_mqtt(packet)
          end
        end
      rescue IO::WaitReadable
        res, _, __ = IO.select([@socket, @stop_read], nil, nil, TIMEOUT)
        break if res.nil? || res.include?(@stop_read)
        retry
      rescue IOError
        # Disconnected
        $logger.error "IOError for client #{self.object_id}"
        break
      rescue MQTT::ProtocolException => e
        $logger.error e.full_message(highlight: false, order: :top)
      end
    end
  ensure
    @mutex.synchronize do
      @connected = false
      @socket.close
    end
    $logger.info "Client disconnected #{self.object_id}..."
  end

  # MQTT packet type 0 is reserved, and Bluetti uses it for two special
  # packets before sending an official MQTT connection packet. This parses
  # those packets and responds appropriately.
  def handle_mqtt_special(data)
    case data[1]
    when "\x01".b
      # Parse packet
      str_len = data[2, 2].unpack('n').first
      @iot_id = data[4, str_len]
      $logger.info "Client #{@iot_id} connected"

      # Handle response
      stamp = [Time.now.to_i - 8 * 60 * 60].pack('N')
      write_nonblock("\x00\x01\x00\x04#{stamp}")
    when "\x02".b
      # Parse packet
      str_len = data[2, 2].unpack('n').first
      @device_type, @serial_number = data[4, str_len].split('&')
      $logger.info "Client device #{@device_type}, serial number #{@serial_number}..."

      # Handle response
      write_nonblock("\x00\x02\x00\x01\x01")
    else
      raise 'Unknown message'
    end
  end

  def handle_mqtt(packet)
    case packet
    when MQTT::Packet::Connect
      $logger.info "MQTT Connect: #{packet.inspect} password: #{packet.password.inspect}"
      write_nonblock(MQTT::Packet::Connack.new)
      @mutex.synchronize { @connected = true }
    when MQTT::Packet::Subscribe
      $logger.info "MQTT Subscribe: #{packet.inspect}"
      topic_names = packet.topics.map { _1[0] }
      @mutex.synchronize { @subscribes.concat(topic_names) }

      return_codes = topic_names.map { 0 }
      write_nonblock(MQTT::Packet::Suback.new(return_codes: return_codes))
    when MQTT::Packet::Publish
      @server.handle_publish(packet)
    when MQTT::Packet::Pingreq
      write_nonblock(MQTT::Packet::Pingresp.new)
    when MQTT::Packet::Disconnect
      $logger.info 'Disconnect request'
      @mutex.synchronize do
        @connected = false
        @socket.close
      end
    else
      $logger.warn "Received unexpected packet: #{packet.inspect}"
    end
  end

  def write_nonblock(data)
    @mutex.synchronize do
      @socket.write_nonblock(data)
    end
  end
end

class MqttDebugServer
  PORT = 18760

  def initialize
    @mutex = Mutex.new
    @stop_read, @stop_write = IO.pipe
    @thread = nil
    @clients = []
    @publishes = Queue.new
  end

  def start
    handle_publish_queue
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

  def handle_publish(packet)
    @publishes << packet
  end

  private

  def run
    $logger.info "Starting MQTT server on port #{PORT}..."
    server = TCPServer.new(PORT)
    loop do
      begin
        socket = server.accept_nonblock
        client = MqttClient.new(socket, self)
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

  def handle_publish_queue
    @publish_thread = Thread.new do
      while (packet = @publishes.deq)
        @clients.each do |client|
          next unless client.connected?

          subscribes = client.subscribes
          next unless subscribes.include?(packet.topic)
          
          client.publish(packet)
        end
      end
    end
    @publish_thread.abort_on_exception = true
  end
end

$logger = Logger.new($stdout)
$stdout.sync = true

# Start debug server
mqtt_server = MqttDebugServer.new.start

# Start up signal handlers
r, w = IO.pipe
main_thread = Thread.current
signal_handler = Thread.new do
  while (io = IO.select([r]))
    mqtt_server.stop
    break
  end
  main_thread.run # Wake up from sleep
end
%w[INT TERM].each { |s| Signal.trap(s) { w.puts(s) } }

# Sleep forever
sleep
