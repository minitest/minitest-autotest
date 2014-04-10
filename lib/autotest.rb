require "pp" # HACK
require "find"
require "minitest/server"
require "rbconfig"

##
# Autotest continuously scans the files in your project for changes
# and runs the appropriate tests.  Test failures are run until they
# have all passed. Then the full test suite is run to ensure that
# nothing else was inadvertantly broken.
#
# If you want Autotest to start over from the top, hit ^C once.  If
# you want Autotest to quit, hit ^C twice.
#
# Rails:
#
# The autotest command will automatically discover a Rails directory
# by looking for config/environment.rb. When Rails is discovered,
# autotest uses RailsAutotest to perform file mappings and other work.
# See RailsAutotest for details.
#
# Plugins:
#
# Plugins are available by creating a .autotest file either in your
# project root or in your home directory. You can then write event
# handlers in the form of:
#
#   Autotest.add_hook hook_name { |autotest| ... }
#
# The available hooks are listed in +ALL_HOOKS+.
#
# See example_dot_autotest.rb for more details.
#
# If a hook returns a true value, it signals to autotest that the hook
# was handled and should not continue executing hooks.
#
# Naming:
#
# Autotest uses a simple naming scheme to figure out how to map
# implementation files to test files following the Test::Unit naming
# scheme.
#
# * Test files must be stored in test/
# * Test files names must start with test_
# * Test class names must start with Test
# * Implementation files must be stored in lib/
# * Implementation files must match up with a test file named
#   test_.*<impl-name>.rb
#
# Strategy:
#
# 1. Find all files and associate them from impl <-> test.
# 2. Run all tests.
# 3. Scan for failures.
# 4. Detect changes in ANY (ruby?. file, rerun all failures + changed files.
# 5. Until 0 defects, goto 3.
# 6. When 0 defects, goto 2.

class Autotest

  TOPDIR = Dir.pwd + "/"

  def self.options
    @@options ||= {}
  end

  def options
    self.class.options
  end

  WINDOZE = /mswin|mingw/ =~ RbConfig::CONFIG['host_os']
  SEP = WINDOZE ? '&' : ';'

  # @@discoveries = []

  def self.parse_options args = ARGV
    require 'optparse'
    options = {
      :args => args.dup
    }

    OptionParser.new do |opts|
      opts.banner = <<-BANNER.gsub(/^        /, '')
        Continuous testing for your ruby app.

          Autotest automatically tests code that has changed. It assumes
          the code is in lib, and tests are in test/test_*.rb. Autotest
          uses plugins to control what happens. You configure plugins
          with require statements in the .autotest file in your
          project base directory, and a default configuration for all
          your projects in the .autotest file in your home directory.

        Usage:
            autotest [options]
      BANNER

      opts.on "-d", "--debug", "Debug mode, for reporting bugs." do
        options[:debug] = true
      end

      opts.on "-v", "--verbose", "Be annoyingly verbose (debugs .autotest)." do
        options[:verbose] = true
      end

      opts.on "-q", "--quiet", "Be quiet." do
        options[:quiet] = true
      end

      opts.on "-h", "--help", "Show this." do
        puts opts
        exit 1
      end
    end.parse! args

    Autotest.options.merge! options

    options
  end

  ##
  # Initialize and run the system.

  def self.run
    new.run
  end

  attr_writer :known_files
  attr_accessor :extra_files
  attr_accessor :files_to_test
  attr_accessor :find_order
  attr_accessor :interrupted
  attr_accessor :failures
  attr_accessor :last_mtime
  attr_accessor :libs
  attr_accessor :output
  attr_accessor :prefix
  attr_accessor :results
  attr_accessor :sleep
  attr_accessor :tainted
  attr_accessor :testlib
  attr_accessor :testprefix
  attr_accessor :find_directories
  attr_accessor :wants_to_quit
  attr_accessor :test_mappings

  alias tainted? tainted

  ##
  # Initialize the instance and then load the user's .autotest file, if any.

  def initialize
    # these two are set directly because they're wrapped with
    # add/remove/clear accessor methods
    @exception_list = []
    @child = nil
    self.test_mappings = []
    self.extra_files       = []
    self.failures          = Hash.new { |h,k| h[k] = Hash.new { |h2,k2| h2[k2] = [] } }
    self.files_to_test     = new_hash_of_arrays
    self.find_order        = []
    self.known_files       = nil
    self.libs              = %w[. lib test ../../minitest/dev/lib].join(File::PATH_SEPARATOR)
    self.output            = $stderr
    self.prefix            = nil
    self.sleep             = 1
    self.testlib           = "minitest/autorun" # TODO: rename
    self.testprefix        = "gem 'minitest'" # TODO: rename

    specified_directories  = ARGV.reject { |arg| arg.start_with?("-") } # options are not directories
    self.find_directories  = specified_directories.empty? ? ['.'] : specified_directories

    # file in /lib -> run test in /test
    self.add_mapping(/^lib\/.*\.rb$/) do |filename, _|
      possible = File.basename(filename).gsub '_', '_?'
      files_matching %r%^test/.*#{possible}$%
    end

    # file in /test -> run it
    self.add_mapping(/^test.*\/test_.*rb$/) do |filename, _|
      filename
    end
  end

  ##
  # Repeatedly run failed tests, then all tests, then wait for changes
  # and carry on until killed.

  def run
    Minitest::Server.run self

    reset
    add_sigint_handler

    self.last_mtime = Time.now if options[:no_full_after_start]

    self.debug if options[:debug]

    loop do
      begin # ^c handler
        get_to_green
        if tainted? and not options[:no_full_after_failed] then
          rerun_all_tests
        end
        wait_for_changes
      rescue Interrupt
        break if wants_to_quit
        reset
      end
    end

    puts
  ensure
    Minitest::Server.stop
  end

  ##
  # Keep running the tests after a change, until all pass.

  def get_to_green
    begin
      run_tests
      wait_for_changes unless all_good
    end until all_good
  end

  ##
  # Look for files to test then run the tests and handle the results.

  def run_tests
    new_mtime = self.find_files_to_test
    return unless new_mtime
    self.last_mtime = new_mtime

    cmd = self.make_test_cmd self.files_to_test
    return if cmd.empty?

    puts cmd unless options[:quiet]

    system cmd
  end

  ############################################################
  # Utility Methods, not essential to reading of logic

  ##
  # Installs a sigint handler.

  def add_sigint_handler
    trap 'INT' do
      Process.kill "KILL", @child if @child

      if self.interrupted then
        self.wants_to_quit = true
      else
        puts "Interrupt a second time to quit"
        self.interrupted = true
        Kernel.sleep 1.5
        raise Interrupt, nil # let the run loop catch it
      end
    end
  end

  ##
  # If there are no files left to test (because they've all passed),
  # then all is good.

  def all_good
    failures.empty?
  end

  ##
  # Find the files to process, ignoring temporary files, source
  # configuration management files, etc., and return a Hash mapping
  # filename to modification time.

  def find_files
    result = {}
    targets = self.find_directories + self.extra_files
    self.find_order.clear

    targets.each do |target|
      order = []
      Find.find target do |f|
        # Find.prune if f =~ self.exceptions
        Find.prune if f =~ /^\.\/tmp/    # temp dir, used by isolate

        next unless File.file? f
        next if f =~ /(swp|~|rej|orig)$/ # temporary/patch files
        next if f =~ /(,v)$/             # RCS files
        next if f =~ /\/\.?#/            # Emacs autosave/cvs merge files

        filename = f.sub(/^\.\//, '')

        result[filename] = File.stat(filename).mtime rescue next
        order << filename
      end
      self.find_order.push(*order.sort)
    end

    result
  end

  ##
  # Find the files which have been modified, update the recorded
  # timestamps, and use this to update the files to test. Returns
  # the latest mtime of the files modified or nil when nothing was
  # modified.

  def find_files_to_test files = find_files
    updated = files.select { |filename, mtime| self.last_mtime < mtime }

    # nothing to update or initially run
    unless updated.empty? || self.last_mtime.to_i == 0 then
      p updated if options[:verbose]

      # hook :updated, updated
    end

    updated.map { |f,m| test_files_for f }.flatten.uniq.each do |filename|
      self.failures[filename] # creates key with default value
      self.files_to_test[filename] # creates key with default value
    end

    if updated.empty? then
      nil
    else
      files.values.max
    end
  end

  ##
  # Lazy accessor for the known_files hash.

  def known_files
    unless @known_files then
      @known_files = Hash[*find_order.map { |f| [f, true] }.flatten]
    end
    @known_files
  end

  ##
  # Generate the commands to test the supplied files

  def make_test_cmd files_to_test
    cmds = []
    full, partial = reorder(failures).partition { |k,v| v.empty? }

    unless full.empty? then
      classes = full.map {|k,v| k}.flatten.uniq
      classes.unshift testlib
      classes = classes.join " "
      cmds << "#{ruby_cmd} -e \"#{testprefix}; %w[#{classes}].each { |f| require f }\" -- -a"
    end

    unless partial.empty? then
      files = partial.map(&:first).sort # no longer a hash because of partition
      re = []

      partial.each do |path, klasses|
        klasses.each do |klass,methods|
          re << /#{klass}##{Regexp.union(methods)}/
        end
      end

      loader = "%w[#{files.join " "}].each do |f| load f; end"
      re = Regexp.union(re).to_s.gsub(/-mix/, "")

      cmds << "#{ruby_cmd} -e '#{loader}' -- -a -n '/#{re}/'"
    end

    cmds.join "#{SEP} "
  end

  def new_hash_of_arrays
    Hash.new { |h,k| h[k] = [] }
  end

  def reorder files_to_test
    max = files_to_test.size
    files_to_test.sort_by { |k,v| rand max }
  end

  ##
  # Rerun the tests from cold (reset state)

  def rerun_all_tests
    reset
    run_tests
  end

  ##
  # Clear all state information about test failures and whether
  # interrupts will kill autotest.

  def reset
    self.files_to_test.clear
    self.find_order.clear

    self.interrupted   = false
    self.known_files   = nil
    self.last_mtime    = Time.at 0
    self.tainted       = false
    self.wants_to_quit = false
  end

  ##
  # Determine and return the path of the ruby executable.

  def ruby
    ruby = ENV['RUBY']
    ruby ||= File.join(RbConfig::CONFIG['bindir'],
                       RbConfig::CONFIG['ruby_install_name'])

    ruby.gsub! File::SEPARATOR, File::ALT_SEPARATOR if File::ALT_SEPARATOR

    return ruby
  end

  ##
  # Returns the base of the ruby command.

  def ruby_cmd
    "#{prefix}#{ruby} -I#{libs} -rubygems"
  end

  ##
  # Return the name of the file with the tests for filename by finding
  # a +test_mapping+ that matches the file and executing the mapping's
  # proc.

  def test_files_for filename
    result = []

    self.test_mappings.each do |file_re, proc|
      if filename =~ file_re then
        result = [proc.call(filename, $~)].
          flatten.sort.uniq.select { |f| known_files[f] }
        break unless result.empty?
      end
    end

    p :test_file_for => [filename, result.first] if result and options[:debug]

    output.puts "No tests matched #{filename}" if
      options[:verbose] and result.empty?

    return result
  end

  ##
  # Sleep then look for files to test, until there are some.

  def wait_for_changes
    Kernel.sleep self.sleep until find_files_to_test
  end

  ############################################################
  # File Mappings:

  ##
  # Returns all known files in the codebase matching +regexp+.

  def files_matching regexp
    self.find_order.select { |k| k =~ regexp }
  end

  ##
  # Adds a file mapping, optionally prepending the mapping to the
  # front of the list if +prepend+ is true. +regexp+ should match a
  # file path in the codebase. +proc+ is passed a matched filename and
  # Regexp.last_match. +proc+ should return an array of tests to run.
  #
  # For example, if test_helper.rb is modified, rerun all tests:
  #
  #   at.add_mapping(/test_helper.rb/) do |f, _|
  #     at.files_matching(/^test.*rb$/)
  #   end

  def add_mapping regexp, prepend = false, &proc
    if prepend then
      @test_mappings.unshift [regexp, proc]
    else
      @test_mappings.push [regexp, proc]
    end
    nil
  end
end
