require 'prometheus_exporter'
require 'prometheus_exporter/server'

module PowerStation
  class MetricsServer
    def initialize(event_bus)
      @event_bus = event_bus
      
      @mutex = Mutex.new
      @elapsed_hours = {}
      @thread = nil
    end

    def start
      @server = PrometheusExporter::Server::WebServer.new({})
      @server.start

      register_metrics
      @event_bus.add_subscriber(self)

      self
    end

    def stop
      $logger.info 'Stopping metrics server...'
      @server.stop
      $logger.info 'Metrics server stopped'
    end

    def handle_event(event)
      device_state = event.device_state
      labels = { device_type: device_state.device_type, serial_number: event.client_id }
      if device_state.has?('solar_power')
        value = device_state.fetch('solar_power')
        @solar_power.observe(value, labels)
        @solar_power_wh.observe(value * elapsed_hours('solar_power'), labels)
      end
      if device_state.has?('grid_power')
        value = device_state.fetch('grid_power')
        @grid_power.observe(value, labels)
        @grid_power_wh.observe(value * elapsed_hours('grid_power'), labels)
      end
      if device_state.has?('ac_output_power')
        value = device_state.fetch('ac_output_power')
        @ac_output_power.observe(value, labels)
        @ac_output_power_wh.observe(value * elapsed_hours('ac_output_power'), labels)
      end
      if device_state.has?('dc_output_power')
        value = device_state.fetch('dc_output_power')
        @dc_output_power.observe(value, labels)
        @dc_output_power_wh.observe(value * elapsed_hours('dc_output_power'), labels)
      end
      if device_state.has?('total_battery_percent')
        @total_battery_percent.observe(device_state.fetch('total_battery_percent'), labels)
      end
      if device_state.has?('pack_battery_percent')
        @pack_battery_percent.observe(device_state.fetch('pack_battery_percent'), labels.merge(pack_num: 1))
      end
      if device_state.has?('packs')
        device_state.fetch('packs').each do |pack|
          pack.fetch('voltages', []).each_with_index do |voltage, i|
            @cell_voltage.observe(
              voltage,
              labels.merge(pack_num: pack['pack_num'], cell_num: i + 1)
            )
          end
        end
      end
    end

    private

    def register_metrics
      @solar_power = build_gauge('solar_power_watts', 'Current solar input')
      @solar_power_wh = build_counter('solar_power_wh', 'Total solar power generation')
      @grid_power = build_gauge('grid_power_watts', 'Current grid input')
      @grid_power_wh = build_counter('grid_power_wh', 'Total grid input')
      @ac_output_power = build_gauge('ac_output_power_watts', 'Current AC power output')
      @ac_output_power_wh = build_counter('ac_output_power_wh', 'Cumulative AC power output')
      @dc_output_power = build_gauge('dc_output_power_watts', 'Current DC power output')
      @dc_output_power_wh = build_counter('dc_output_power_wh', 'Cumulative DC power output')
      @total_battery_percent = build_gauge('total_battery_percent', 'Total battery percent')
      @pack_battery_percent = build_gauge('pack_battery_percent', 'Pack battery percent')
      @cell_voltage = build_gauge('cell_voltage', 'Voltage of a single cell in a pack')
    end

    def elapsed_hours(field_name)
      @mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @elapsed_hours.key?(field_name)
          last_time = @elapsed_hours[field_name]
          @elapsed_hours[field_name] = now
          (now - last_time) / 3600.0
        else
          @elapsed_hours[field_name] = now
          0
        end
      end
    end

    def build_gauge(name, hint = '')
      metric = PrometheusExporter::Metric::Gauge.new(name, hint)
      @server.collector.register_metric(metric)
      metric
    end

    def build_counter(name, hint = '')
      metric = PrometheusExporter::Metric::Counter.new(name, hint)
      @server.collector.register_metric(metric)
      metric
    end
  end
end
