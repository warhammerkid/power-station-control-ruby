module PowerStation
  module MQTT
    class DataPage
      def initialize
        @data = ("\0" * 512).b
      end

      def raw
        @data.dup
      end

      def update(offset, data)
        @data[offset * 2, data.size] = data
      end

      def parse_uint(offset)
        @data[2 * offset, 2].unpack('n').first
      end

      def parse_bool(offset)
        parse_uint(offset) == 1
      end

      # Parses a null-padded fixed-width string. Size is in offset width (16-bit
      # pairs).
      def parse_string(offset, size)
        @data[2 * offset, 2 * size].rstrip
      end
    end

    class StatusPage < DataPage
      def device_type
        parse_string(0x0A, 6)
      end

      # Solar power in watts
      def solar_power
        parse_uint(0x24)
      end

      # Grid power in watts
      def grid_power
        parse_uint(0x25)
      end

      # AC output power in watts
      def ac_output_power
        parse_uint(0x26)
      end

      # DC output power in watts
      def dc_output_power
        parse_uint(0x27)
      end

      # Total battery percent (0-100)
      def battery_percent
        parse_uint(0x2B)
      end

      # AC output switch on/off
      def ac_output_on
        parse_bool(0x30)
      end

      # DC output switch on/off
      def dc_output_on
        parse_bool(0x31)
      end

      # There's only space to show one battery pack's info, so this tells you what
      # pack is currently being shown
      def current_pack
        parse_uint(0x60)
      end

      # TODO: Figure out data structure for what appears to be detailed battery
      # info in the higher ranges
    end

    class ControlPage < DataPage
      TIME_CONTROL_MODE = {
        1 => 'Charge',
        2 => 'Discharge'
      }.freeze
      AUTO_SLEEP = {
        2 => '30s',
        3 => '1 min',
        4 => '5 min',
        5 => 'Never'
      }.freeze
      UPS_MODES = {
        1 => 'Customized UPS',
        2 => 'PV Priority UPS',
        3 => 'Standard UPS',
        4 => 'Time Control UPS'
      }.freeze

      def ups_mode
        UPS_MODES.fetch(parse_uint(0xB9))
      end

      # There's only space to show one battery pack's info, so this tells you what
      # pack is currently selected
      def current_pack
        parse_uint(0xBE)
      end

      # AC output switch on/off
      def ac_output_on
        parse_bool(0xBF)
      end

      # DC output switch on/off
      def dc_output_on
        parse_bool(0xC0)
      end

      # Grid charging switch on/off
      def grid_charge_on
        parse_bool(0xC3)
      end

      # Time control switch on/off
      def time_control_on
        parse_bool(0xC5)
      end

      # Battery range low (AC power cut-off point)
      def battery_range_low
        parse_uint(0xC7)
      end

      # Battery range high (Grid charge cut-off point)
      def battery_range_high
        parse_uint(0xC8)
      end

      # TODO: Figure out why two time ranges are stored as wide times (4 byte time) from 0xCF->0xD6

      # Device time
      def device_time
        byte_offset = 2 * 0xD7
        year_part = @data[byte_offset].ord
        month = @data[byte_offset + 1].ord
        day = @data[byte_offset + 2].ord
        hour = @data[byte_offset + 3].ord
        minute = @data[byte_offset + 4].ord
        second = @data[byte_offset + 5].ord
        '%02d-%02d-%02d %02d:%02d:%02d' % [month, day, year_part, hour, minute, second]
      end

      # True if there's a bluetooth device connected
      def bluetooth_connected
        parse_bool(0xDC)
      end

      %w[time_one time_two time_three time_four time_five time_six].each_with_index do |name, i|
        offset = 0xDF + 3 * i
        define_method("#{name}_mode") do
          TIME_CONTROL_MODE.fetch(read_uint(offset))
        end
        define_method("#{name}_start") do
          parse_two_byte_time(offset + 1)
        end
        define_method("#{name}_end") do
          parse_two_byte_time(offset + 2)
        end
      end

      # Screen auto-sleep delay
      def auto_sleep
        AUTO_SLEEP.fetch(parse_uint(0xF5))
      end

      private

      def parse_two_byte_time(offset)
        byte_offset = 2 * offset
        hour = @data[byte_offset].ord
        minute = @data[byte_offset + 1].ord
        '%02d:%02d' % [hour, minute]
      end
    end

    class WifiPage < DataPage
      def local_ip
        ip_data = @data[2 * 0x8C, 4]
        octets = swap_array_alternates(ip_data.unpack('CCCC'))
        octets.join('.')
      end

      def mac_address
        mac_data = @data[2 * 0x8E, 6]
        parts = swap_array_alternates(mac_data.unpack('H2H2H2H2H2H2'))
        parts.join(':')
      end

      def essid
        parse_swap_string(0x99, 16)
      end

      def password
        parse_swap_string(0xA9, 16)
      end

      # Wi-Fi signal strength (0-100)
      def signal_strength
        parse_uint(0xB9)
      end

      private

      # Parses a null-padded fixed-width string with every other character position
      # swapped. Size is in offset width (16-bit pairs).
      def parse_swap_string(offset, size)
        str_data = @data[2 * offset, 2 * size]
        swap_array_alternates(str_data.each_char).join.rstrip
      end

      def swap_array_alternates(array)
        array.each_slice(2).flat_map { [_2, _1] }
      end
    end
  end
end
