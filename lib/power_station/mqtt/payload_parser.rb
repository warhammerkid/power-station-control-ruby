module PowerStation
  module MQTT
    PayloadField = Struct.new(:name, :page, :offset, :type)

    class PayloadParser
      class << self
        def def_field(name, page, offset, type)
          @fields ||= []
          @fields << PayloadField.new(name, page, offset, type)
        end

        def fields
          @fields || []
        end
      end

      def_field('solar_power', 0x00, 0x24, :uint)
      def_field('grid_power', 0x00, 0x25, :uint)
      def_field('ac_output_power', 0x00, 0x26, :uint)
      def_field('dc_output_power', 0x00, 0x27, :uint)
      def_field('total_battery_percent', 0x00, 0x2B, :uint)

      attr_reader :parsed

      def initialize(page, offset, data)
        @page = page
        @offset = offset
        @data = data
        @parsed = {}
      end

      def parse!
        raise "unexpected size: #{@data.size}" unless @data.size % 2 == 0

        data_range = Range.new(@offset, @offset + @data.size / 2, true)
        fields = self.class.fields.select { @page == _1.page && data_range.include?(_1.offset) }
        return if fields.empty?
    
        fields.each do |field|
          data_start = 2 * (field.offset - @offset)
          case field.type
          in :bool
            value = @data[data_start, 2].unpack('n').first
            @parsed[field.name] = (value == 1)
          in :uint
            value = @data[data_start, 2].unpack('n').first
            @parsed[field.name] = value
          in { string: size }
            value = @data[data_start, 2 * size].rstrip
            @parsed[field.name] = value
          in { enum: enum }
            value = @data[data_start, 2].unpack('n').first
            @parsed[field.name] = enum.fetch(value)
          in { custom: custom, size: size }
            str = @data[data_start, 2 * size].ljust(2 * size, "\x00") # Pad out to size
            value = send("parse_#{custom}", str)
            @parsed[field.name] = value
          end
        end
      end
    end
  end
end
