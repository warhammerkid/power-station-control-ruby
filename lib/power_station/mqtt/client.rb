require 'mqtt'
require 'digest/crc16' # digest-crc gem
require_relative 'payload_parser'
require_relative 'server_commands'

module PowerStation
  module MQTT
    class Client
      PACKET_SIZE = 1380
      TIMEOUT = 60

      attr_reader :device_type, :iot_id, :serial_number

      def initialize(socket, event_bus)
        @socket = socket
        @event_bus = event_bus

        @mutex = Mutex.new
        @stopped = false
        @stop_read, @stop_write = IO.pipe
        @handler_thread = nil
      end

      def start
        @handler_thread = Thread.new(&method(:handle))
        @handler_thread.abort_on_exception = true

        @poller_thread = Thread.new(&method(:poll))
        @poller_thread.abort_on_exception = true

        self
      end

      def stop
        @mutex.synchronize { @stopped = true }
        @poller_thread.run
        @poller_thread.join

        @stop_write.write('stop')
        @handler_thread.join
      end

      private

      def stopped?
        @mutex.synchronize { @stopped }
      end

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
                packet = ::MQTT::Packet.read(stream)
                handle_mqtt(packet)
              end
            end
          rescue IO::WaitReadable
            res, _, __ = IO.select([@socket, @stop_read], nil, nil, TIMEOUT)
            break if res.nil? || res.include?(@stop_read)
            retry
          rescue IOError
            # Disconnected
            break
          rescue ::MQTT::ProtocolException => e
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
        when ::MQTT::Packet::Connect
          write_nonblock(::MQTT::Packet::Connack.new)
        when ::MQTT::Packet::Subscribe
          return_codes = packet.topics.map { 0 }
          write_nonblock(::MQTT::Packet::Suback.new(return_codes: return_codes))
        when ::MQTT::Packet::Publish
          handle_publish(packet.payload)
        when ::MQTT::Packet::Pingreq
          write_nonblock(::MQTT::Packet::Pingresp.new)
        when ::MQTT::Packet::Disconnect
          @mutex.synchronize { @socket.close }
        else
          $logger.warn "Received unexpected packet: #{packet.inspect}"
        end
      end

      def handle_publish(data)
        parser =
          case data[2]
          when "\x03".b
            # Client response to a range request. Assume page and offset from
            # standard lengths.
            len = data[3].ord
            payload = data[4, len].b
            case len
            when 140
              PayloadParser.new(0x00, 0x00, payload)
            when 254
              PayloadParser.new(0x00, 0x46, payload)
            else
              $logger.error "Unknown range response length #{len}: #{payload.inspect}"
            end
          when "\x06".b
            # Single field update
            PayloadParser.new(data[3].ord, data[4].ord, data[5, 2].b)
          when "\x10".b
            # Ignore empty range updates...
            return if data.size == 9

            # Range update
            len = data[7].ord
            PayloadParser.new(data[3].ord, data[4].ord, data[8, len].b)
          else
            $logger.error "Unknown client message: #{data.inspect}"
            return
          end

        # Publish parsed DeviceState
        parser.parse!
        device_state = DeviceState.new(@device_type, parser.parsed)
        @event_bus.broadcast_device_state(@serial_number, device_state)
      end

      def poll
        loop do
          break if stopped?

          if @device_type && @serial_number
            send_query(0x00, 0x00, 70)
            sleep 1
            send_query(0x00, 0x46, 127)
            sleep 1
          else
            sleep 1
          end
        end
      end

      def send_query(page, offset, size)
        payload = RangeQueryCommand.new(page, offset, size).to_s
        payload << Checksum.digest(payload)

        packet = ::MQTT::Packet::Publish.new(
          topic: "SUB/#{@device_type}/#{@serial_number}",
          payload: payload
        )

        write_nonblock(packet)
      end

      def write_nonblock(data)
        @mutex.synchronize do
          @socket.write_nonblock(data)
        end
      end

      class Checksum < Digest::CRC16
        INIT_CRC = 0xFE55

        def self.pack(crc)
          buffer = ''
      
          buffer << (crc & 0xff).chr
          buffer << ((crc & 0xff00) >> 8).chr
      
          buffer
        end
      end
    end
  end
end
