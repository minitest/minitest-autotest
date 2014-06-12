require "drb"
require "tmpdir"

module Minitest
  class Server
    def self.path pid = $$
      "drbunix:#{Dir.tmpdir}/autotest.#{pid}"
    end

    def self.run autotest
      DRb.start_service path, new(autotest)
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
