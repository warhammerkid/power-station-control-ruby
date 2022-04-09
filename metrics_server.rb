require 'prometheus_exporter'
require 'prometheus_exporter/server'

class MetricsServer
  def initialize(mqtt_server)
    @mqtt_server = mqtt_server
    
    @mutex = Mutex.new
    @thread = nil
    @stopped = false
    @last_times = {}
  end

  def start
    @server = PrometheusExporter::Server::WebServer.new({})
    @server.start

    @thread = Thread.new(&method(:run))
    @thread.abort_on_exception = true

    self
  end

  def stop
    $logger.info 'Stopping metrics server...'
    @mutex.synchronize { @stopped = true }
    @thread.run # Wake up...
    @thread.join
    $logger.info 'Metrics server stopped'
  end

  private

  def run
    $logger.info 'Starting metrics server...'

    solar_power = build_gauge('solar_power_watts', 'Current solar input')
    solar_power_wh = build_counter('solar_power_wh', 'Total solar power generation')
    grid_power = build_gauge('grid_power_watts', 'Current grid input')
    grid_power_wh = build_counter('grid_power_wh', 'Total grid input')
    ac_output_power = build_gauge('ac_output_power_watts', 'Current AC power output')
    ac_output_power_wh = build_counter('ac_output_power_wh', 'Cumulative AC power output')
    dc_output_power = build_gauge('dc_output_power_watts', 'Current DC power output')
    dc_output_power_wh = build_counter('dc_output_power_wh', 'Cumulative DC power output')
    total_battery_percent = build_gauge('total_battery_percent', 'Total battery percent')

    loop do
      break if stopped?

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Refresh data
      @mqtt_server.clients.each do |client|
        break if stopped?

        page = client.request_update(0x00, 0x24, 13)
        next if page.nil?

        labels = { device_type: client.device_type, serial_number: client.serial_number }
        elapsed_hours = get_elapsed_hours(client.serial_number)

        solar_power.observe(page.solar_power, labels)
        solar_power_wh.observe(page.solar_power * elapsed_hours, labels)
        grid_power.observe(page.grid_power, labels)
        grid_power_wh.observe(page.grid_power * elapsed_hours, labels)
        ac_output_power.observe(page.ac_output_power, labels)
        ac_output_power_wh.observe(page.ac_output_power * elapsed_hours, labels)
        dc_output_power.observe(page.dc_output_power, labels)
        dc_output_power_wh.observe(page.dc_output_power * elapsed_hours, labels)
        total_battery_percent.observe(page.battery_percent, labels)
      end

      refresh_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      sleep [2 - refresh_duration, 0].max
    end
  end

  def stopped?
    @mutex.synchronize { @stopped }
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

  def get_elapsed_hours(serial_number)
    if @last_times.key?(serial_number)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed_hours = (now - @last_times[serial_number]) / 3600.0
      @last_times[serial_number] = now
      elapsed_hours
    else
      @last_times[serial_number] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      0
    end
  end
end
