require 'drb'

class Minitest
  class Server
    URI = "druby://localhost:8787"

    def self.run autotest
      DRb.start_service URI, new(autotest)
      # DRb.thread.join
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
      pp failures
    end
  end
end
