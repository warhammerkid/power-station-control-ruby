require 'mqtt'
require_relative 'data_pages'

class MqttClient
  PACKET_SIZE = 1380
  TIMEOUT = 60

  attr_reader :device_type, :iot_id, :pages, :serial_number

  def initialize(socket)
    @socket = socket

    @mutex = Mutex.new
    @thread = nil
    @pages = {
      0x00 => StatusPage.new,
      0x0B => ControlPage.new,
      0x13 => WifiPage.new
    }
  end

  def start
    @thread = Thread.new(&method(:handle))
    @thread.abort_on_exception = true
    self
  end

  def stop
    @socket.close
  end

  private

  def handle
    $logger.info "New client connected #{self.object_id}..."
    loop do
      begin
        data = @socket.read_nonblock(PACKET_SIZE)
        if data[0] == "\x00".b
          handle_bluetti_special(data)
        else
          packet = MQTT::Packet.parse(data)
          handle_mqtt(packet)
        end
      rescue IO::WaitReadable
        res, _, __ = IO.select([@socket], nil, nil, TIMEOUT)
        break if res.nil?
        retry
      rescue MQTT::ProtocolException => e
        $logger.error e.full_message(highlight: false, order: :top)
      end
    end
  ensure
    @socket.close
    $logger.info "Client disconnected #{self.object_id}..."
  end

  # MQTT packet type 0 is reserved, and Bluetti uses it for two special
  # packets before sending an official MQTT connection packet. This parses
  # those packets and responds appropriately.
  def handle_bluetti_special(data)
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
      write_nonblock(MQTT::Packet::Connack.new)
    when MQTT::Packet::Subscribe
      return_codes = packet.topics.map { 0 }
      write_nonblock(MQTT::Packet::Suback.new(return_codes: return_codes))
    when MQTT::Packet::Publish
      handle_bluetti_publish(packet.payload)
    when MQTT::Packet::Pingreq
      write_nonblock(MQTT::Packet::Pingresp.new)
    when MQTT::Packet::Disconnect
      @mutex.synchronize { @socket.close }
    else
      $logger.warn "Received unexpected packet: #{packet.inspect}"
    end
  end

  def handle_bluetti_publish(data)
    case data[2]
    when "\x03".b
      # Client response to a range request
      raise 'unhandled'
    when "\x06".b
      # Single field update
      page = @pages.fetch(data[3].ord)
      page.update(data[4].ord, data[5, 2].b)
    when "\x10".b
      # Ignore empty range updates...
      return if data.size == 9

      # Range update
      page = @pages.fetch(data[3].ord)
      len = data[7].ord
      page.update(data[4].ord, data[8, len].b)
    else
      $logger.error "Unknown client message: #{data.inspect}"
    end
  end

  def write_nonblock(data)
    @mutex.synchronize do
      @socket.write_nonblock(data)
    end
  end
end
