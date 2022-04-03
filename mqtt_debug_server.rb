require 'logger'
require 'socketry'
require 'mqtt'

class ClientHandler
  def initialize(socket, server, logger)
    @socket = socket
    @server = server
    @logger = logger
    
    @mutex = Mutex.new
    @subscribes = []
    @connected = false
  end
  
  def start
    Thread.new(&method(:handle))
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

  # Loop forever...
  def handle
    @logger.info "Connected #{self.object_id}..."
    loop do
      # Listen for new data
      data = @socket.readpartial(1024, timeout: 60)
      break if data == :eof

      io = StringIO.new(data)
      if data[0] == "\x00".b
        handle_bluetti_special(io)
      else
        packet = MQTT::Packet.read(io)
        handle_mqtt(packet)
      end
    end
  rescue => e
    @logger.error e.inspect
  ensure
    @logger.warn 'Closing connection...'
    @mutex.synchronize do
      @connected = false
      @socket.close
    end
  end
  
  def handle_bluetti_special(io)
    io.getbyte # The first byte is 0x00
    case io.getbyte
    when 1
      # Parse packet
      str_len = read_uint(io)
      @iot_id = io.read(str_len)
      @logger.info "Client #{@iot_id} connected"
      
      # Handle response
      stamp = [Time.now.to_i - 8 * 60 * 60].pack('N')
      @socket.write_nonblock("\x00\x01\x00\x04#{stamp}")
    when 2
      # Parse packet
      str_len = read_uint(io)
      @client_sn = io.read(str_len)
      @logger.info "Client sn: #{@client_sn}"
      
      # Handle response
      @socket.write_nonblock("\x00\x02\x00\x01\x01")
    else
      raise 'Unknown message'
    end
  end
  
  def handle_mqtt(packet)
    case packet
    when MQTT::Packet::Connect
      @logger.info "MQTT Connect: #{packet.inspect} password: #{packet.password.inspect}"
      @mutex.synchronize do
        @connected = true
        @socket.write_nonblock(MQTT::Packet::Connack.new)
      end
    when MQTT::Packet::Subscribe
      @logger.info "MQTT Subscribe: #{packet.inspect}"
      topic_names = packet.topics.map { _1[0] }
      @mutex.synchronize { @subscribes.concat(topic_names) }

      return_codes = topic_names.map { 0 }
      response = MQTT::Packet::Suback.new(return_codes: return_codes)
      @mutex.synchronize { @socket.write_nonblock(response) }
    when MQTT::Packet::Publish
      @server.handle_publish(packet)
    when MQTT::Packet::Pingreq
      @mutex.synchronize { @socket.write_nonblock(MQTT::Packet::Pingresp.new) }
    when MQTT::Packet::Disconnect
      @mutex.synchronize do
        @connected = false
        @socket.close
      end
    else
      @logger.warn "Received unexpected packet: #{packet.inspect}"
    end
  end

  # Reads a 2 byte unsigned int from the given stream and returns it
  def read_uint(io)
    io.read(2).unpack('n').first
  end
end

class BluettiMqttServer
  def initialize(port, logger)
    @port = port
    @logger = logger

    @mutex = Mutex.new
    @stopped = false
    @thread = nil
    @server = nil
    @clients = []
    @publishes = Queue.new
  end
  
  def start
    handle_signals
    handle_publish_queue
    @thread = Thread.new(&method(:run))
    @thread.abort_on_exception = true
    sleep
  end
  
  def stop
    @logger.info 'Stopping server...'
    @mutex.synchronize { @stopped = true }
    @thread.join
  end
  
  def handle_publish(packet)
    @publishes << packet
  end
  
  private
  
  def run
    @logger.info "Starting server on port #{@port}..."
    @server = Socketry::TCP::Server.new(@port)
    loop do
      break if stopped?

      begin
        socket = @server.accept(timeout: 1)
        
        @logger.info 'New connection received...'
        client_handler = ClientHandler.new(socket, self, @logger)
        @clients << client_handler
        client_handler.start
      rescue Socketry::TimeoutError
        # Ignored
      end
    end
  ensure
    @server.close
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
  
  def stopped?
    @mutex.synchronize { @stopped }
  end
  
  def handle_signals
    r, w = IO.pipe
    main_thread = Thread.current
    @signal_handler = Thread.new do
      while (io = IO.select([r]))
        stop
        break
      end
      main_thread.run # Wake up from sleep
    end
    %w[INT TERM].each { |s| Signal.trap(s) { w.puts(s) } }
  end
end

BluettiMqttServer.new(
  18760,
  Logger.new($stdout)
).start

