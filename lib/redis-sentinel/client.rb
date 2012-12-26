require "redis"

class Redis::Client
  class_eval do
    def initiliaze_with_sentinel(options={})
      @master_name = options.delete(:master_name) || options.delete("master_name")
      @sentinels = options.delete(:sentinels) || options.delete("sentinels")
      @watcher = Thread.new { watch_sentinel } if sentinel?
      initialize_without_sentinel(options)
    end

    alias initialize_without_sentinel initialize
    alias initialize initiliaze_with_sentinel

    def connect_with_sentinel
      discover_master if sentinel?
      connect_without_sentinel
    end

    alias connect_without_sentinel connect
    alias connect connect_with_sentinel

    def sentinel?
      @master_name && @sentinels
    end

    def try_next_sentinel
      @sentinels << @sentinels.shift
      if @logger && @logger.debug?
        @logger.debug? "Trying next sentinel: #{@sentinels[0][:host]}:#{@sentinels[0][:port]}"
      end
      return @sentinels[0]
    end

    def discover_master
      masters = []

      while true
        sentinel = Redis.new(@sentinels[0])

        begin
          host, port = sentinel.sentinel("get-master-addr-by-name", @master_name)
          if !host && !port
            raise Redis::ConnectionError("No master named: #{@master_name}")
          end
          @options.merge!(host: host, port: port.to_i)

          break
        rescue Redis::CannotConnectError
          try_next_sentinel
        end
      end
    end

    def watch_sentinel
      while true
        sentinel = Redis.new(@sentinels[0])

        begin
          sentinel.psubscribe("*") do |on|
            on.pmessage do |pattern, channel, message|
              next if channel != "+switch-master"

              master_name, old_host, old_port, new_host, new_port = message.split(" ")

              next if master_name != @master_name

              @options.merge!(host: new_host, port: new_port.to_i)

              if @logger && @logger.debug?
                @logger.debug "Failover: #{old_host}:#{old_port} => #{new_host}:#{new_port}"
              end

              disconnect
            end
          end
        rescue Redis::CannotConnectError
          try_next_sentinel
          sleep 1
        end
      end
    end
  end
end