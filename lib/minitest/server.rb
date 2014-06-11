require 'drb'

module Minitest
  class Server
    port = ENV["DRBPORT"] || 8787
    URI = "druby://:#{port}"

    def self.run autotest
      DRb.start_service URI, new(autotest)
    rescue Errno::EADDRINUSE
      abort "Address #{URI} is already in use. Use $DRBPORT or -p # to change."
    end

    def self.stop
      DRb.stop_service
    end

    attr_accessor :autotest, :failures

    def initialize autotest
      self.autotest = autotest
      self.failures = autotest.failures
    end

    def quit
      self.class.stop
    end

    def start
      warn "SERVER: Starting"
      failures.clear
    end

    def failure file, class_name, test_name
      file = file.sub(/^#{Autotest::TOPDIR}/, "")
      autotest.tainted = true
      failures[file][class_name] << test_name
    end

    def report
      warn "SERVER: done"
    end
  end
end
