module PowerStation
  module MQTT
    class PayloadParser
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

      attr_reader :parsed

      def initialize(page, offset, data)
        @page = page
        @offset = offset
        @data = data
        @parsed = {}
      end

      def parse!
        raise "unexpected size: #{@data.size}" unless @data.size % 2 == 0

        case @page
        when 0x00 then parse_status_page!
        when 0x0B then parse_control_page!
        when 0x13 then parse_wifi_page!
        end
      end

      private

      def parse_status_page!
        parse_field('device_type', 0x0A, { string: 6 })
        parse_field('dc_input_power', 0x24, :uint)
        parse_field('ac_input_power', 0x25, :uint)
        parse_field('ac_output_power', 0x26, :uint)
        parse_field('dc_output_power', 0x27, :uint)
        parse_field('total_battery_percent', 0x2B, :uint)
        parse_field('ac_output_on', 0x30, :bool)
        parse_field('dc_output_on', 0x31, :bool)
        parse_field('pack_battery_percent', 0x5E, :uint)

        # Parse out pack data
        if data_available?(0x60, 1)
          pack_data = { 'pack_num' => read_uint(0x60) }
          if data_available?(0x69, 16)
            pack_data['voltages'] = parse_voltages(read_data(0x69, 16))
          end
          @parsed['packs'] = [pack_data]
        end
      end

      def parse_control_page!
        parse_field('ups_mode', 0xB9, { enum: UPS_MODES })
        parse_field('ac_output_on', 0xBF, :bool)
        parse_field('dc_output_on', 0xC0, :bool)
        parse_field('grid_charge_on', 0xC3, :bool)
        parse_field('time_control_on', 0xC5, :bool)
        parse_field('battery_range_start', 0xC7, :uint)
        parse_field('battery_range_end', 0xC8, :uint)
        parse_field('device_time', 0xD7, { custom: :date, size: 3 })
        %w[time_one time_two time_three time_four time_five time_six].each_with_index do |name, i|
          offset = 0xDF + 3 * i
          parse_field("#{name}_mode", offset, { enum: TIME_CONTROL_MODE })
          parse_field("#{name}_start", offset + 1, { custom: :two_byte_time, size: 1 })
          parse_field("#{name}_end", offset + 2, { custom: :two_byte_time, size: 1 })
        end
        parse_field('auto_sleep', 0xF5, { enum: AUTO_SLEEP })
      end

      def parse_wifi_page!
        if data_available?(0x8C, 2)
          ip_data = read_data(0x8C, 2)
          octets = swap_array_alternates(ip_data.unpack('CCCC'))
          @parsed['local_ip'] = octets.join('.')
        end

        if data_available?(0x8E, 3)
          mac_data = read_data(0x8E, 3)
          parts = swap_array_alternates(mac_data.unpack('H2H2H2H2H2H2'))
          @parsed['mac_address'] = parts.join(':')
        end

        parse_field('essid', 0x99, { custom: :swap_string, size: 16 })
        parse_field('wifi_password', 0xA9, { custom: :swap_string, size: 16 })
        parse_field('wifi_signal_strength', 0xB9, :uint)
      end

      # Parse the given offset into the given field if the data is available
      def parse_field(name, offset, type)
        case type
        in :bool
          return unless data_available?(offset, 1)
          value = read_uint(offset)
          @parsed[name] = (value == 1)
        in :uint
          return unless data_available?(offset, 1)
          value = read_uint(offset)
          @parsed[name] = value
        in { enum: enum }
          return unless data_available?(offset, 1)
          value = read_uint(offset)
          @parsed[name] = enum.fetch(value)
        in { string: size }
          return unless data_available?(offset, size)
          value = read_data(offset, size).rstrip
          @parsed[name] = value
        in { custom: custom, size: size }
          return unless data_available?(offset, size)
          str = read_data(offset, size)
          value = send("parse_#{custom}", str)
          @parsed[name] = value
        end
      end

      def parse_voltages(data)
        data.unpack('n*').map { _1 / 100.0 }
      end

      def parse_date(data)
        year_part = data[0].ord
        month = data[1].ord
        day = data[2].ord
        hour = data[3].ord
        minute = data[4].ord
        second = data[5].ord
        '%02d-%02d-%02d %02d:%02d:%02d' % [month, day, year_part, hour, minute, second]
      end

      def parse_two_byte_time(data)
        hour = data[0].ord
        minute = data[1].ord
        '%02d:%02d' % [hour, minute]
      end

      # Parses a null-padded fixed-width string with every other character position
      # swapped. Size is in offset width (16-bit pairs).
      def parse_swap_string(data)
        swap_array_alternates(data.each_char).join.rstrip
      end

      def swap_array_alternates(array)
        array.each_slice(2).flat_map { [_2, _1] }
      end

      # Reads a uint at the given offset
      def read_uint(offset)
        read_data(offset, 1).unpack('n').first
      end

      # Reads from the data at the given offset and size
      def read_data(offset, size)
        raise 'Data not available' unless data_available?(offset, size)

        data_start = 2 * (offset - @offset)
        @data[data_start, 2 * size]
      end

      # Check if data is available for parsing
      def data_available?(offset, size)
        check_range = Range.new(offset, offset + size, true)

        @data_range ||= Range.new(@offset, @offset + @data.size / 2, true)
        @data_range.cover?(check_range)
      end
    end
  end
end
