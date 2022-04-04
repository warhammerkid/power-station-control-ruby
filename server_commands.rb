class RangeQueryCommand
  attr_reader :page, :offset, :size

  def initialize(page, offset, size)
    @page = page
    @offset = offset
    @size = size
  end

  def to_s
    payload = "\x01\x01\x03".b
    payload << [@page, @offset, @size].pack('C2n')
    payload
  end
end

class FieldUpdateCommand
  attr_reader :page, :offset, :value

  def initialize(page, offset, value)
    @page = page
    @offset = offset
    @value = value
  end
  
  def to_s
    payload = "\x01\x01\x06".b
    payload << [@page, @offset, @value].pack('C2n')
    payload
  end
end

class RangeUpdateCommand
  attr_reader :page, :offset, :data

  def initialize(page, offset, data)
    @page = page
    @offset = offset
    @data = data
  end
  
  def to_s
    raise "Data size invalid: #{@data.size}" unless @data.size % 2 == 0
    payload = "\x01\x01\x10".b
    payload << [@page, @offset, @data.size / 2, @data.size].pack('C2nC')
    payload << @data
    payload
  end
end
