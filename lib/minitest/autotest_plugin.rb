require "minitest"

module Minitest
  @autotest = false

  def self.plugin_autotest_options opts, options # :nodoc:
    opts.on "-a", "--autotest", "Connect to autotest server." do
      @autotest = true
    end
  end

  def self.plugin_autotest_init options
    if @autotest then
      puts "Adding Autotest Reporter"
      require "minitest/server"
      self.reporter << Minitest::AutotestReporter.new
    end
  end
end

module Minitest
  class AutotestReporter < MiniTest::AbstractReporter
    def initialize
      DRb.start_service
      uri = Minitest::Server::URI
      @at_server = DRbObject.new_with_uri uri
      super
    end

    def start
      @at_server.start
    end

    def record result
      unless result.passed? || result.skipped?
        file, = result.class.instance_method(result.name).source_location
        @at_server.failure file, result.class.name, result.name
      end
    end

    def report
      @at_server.report
    end
  end
end
