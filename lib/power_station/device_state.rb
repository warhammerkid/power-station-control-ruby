module PowerStation
  class DeviceState
    attr_reader :device_type

    def initialize(device_type, data)
      @device_type = device_type
      @data = data
    end

    def has?(key)
      @data.key?(key)
    end

    def fetch(key)
      @data.fetch(key)
    end
  end
end
