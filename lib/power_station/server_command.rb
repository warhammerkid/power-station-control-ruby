# frozen_string_literal: true

require 'digest/crc16_modbus'

module PowerStation
  class ServerCommand
    def to_s
      return @payload if defined?(@payload)

      @payload = payload

      crc = Digest::CRC16Modbus.checksum(@payload)
      @payload << (crc & 0xFF).chr
      @payload << ((crc & 0xFF00) >> 8).chr
      @payload.freeze
    end
  end

  class RangeQueryCommand < ServerCommand
    attr_reader :page, :offset, :size

    def initialize(page, offset, size)
      @page = page
      @offset = offset
      @size = size
    end

    private

    def payload
      "\x01\x03".b + [@page, @offset, @size].pack('C2n')
    end
  end

  class FieldUpdateCommand < ServerCommand
    attr_reader :page, :offset, :value

    def initialize(page, offset, value)
      @page = page
      @offset = offset
      @value = value
    end

    private

    def payload
      "\x01\x06".b + [@page, @offset, @value].pack('C2n')
    end
  end

  class RangeUpdateCommand < ServerCommand
    attr_reader :page, :offset, :data

    def initialize(page, offset, data)
      @page = page
      @offset = offset
      @data = data
    end

    private

    def payload
      raise "Data size invalid: #{@data.size}" unless @data.size % 2 == 0
      payload = "\x01\x10".b + [@page, @offset, @data.size / 2, @data.size].pack('C2nC')
      payload << @data
      payload
    end
  end
end
