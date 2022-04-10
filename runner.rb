require 'logger'
require_relative 'mqtt_server'
require_relative 'metrics_server'
require_relative 'api_server'

$logger = Logger.new($stdout)

# Start up servers
mqtt_server = MqttServer.new.start
metrics_server = MetricsServer.new(mqtt_server).start
api_server = ApiServer.new(mqtt_server, 3000).start

# Start up signal handlers
r, w = IO.pipe
main_thread = Thread.current
signal_handler = Thread.new do
  while (io = IO.select([r]))
    metrics_server.stop
    api_server.stop
    mqtt_server.stop
    break
  end
  main_thread.run # Wake up from sleep
end
%w[INT TERM].each { |s| Signal.trap(s) { w.puts(s) } }

# Sleep forever
sleep