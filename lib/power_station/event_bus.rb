module PowerStation
  class EventBus
    def initialize
      @mutex = Mutex.new
      @thread = nil
      @subscribers = []
      @events = Queue.new
    end

    def start
      @thread = Thread.new(&method(:run))
      @thread.abort_on_exception = true
      self
    end

    def add_subscriber(subscriber)
      @mutex.synchronize do
        @subscribers << subscriber unless @subscribers.include?(subscriber)
      end
    end

    def broadcast_device_state(client_id, device_state)
      @events << Event.new(client_id, device_state)
    end

    private

    def run
      while (event = @events.deq)
        @mutex.synchronize do
          @subscribers.each do |subscriber|
            subscriber.handle_event(event)
          rescue Exception => e
            $logger.error "Event broadcast exception: #{e.full_message(highlight: false, order: :top)}"
          end
        end
      end
    end

    Event = Struct.new(:client_id, :device_state)
  end
end
