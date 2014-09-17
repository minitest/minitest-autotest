require "find"
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

  T0 = Time.at 0

  ALL_HOOKS = [ :all_good, :died, :green, :initialize,
                :post_initialize, :interrupt, :quit, :ran_command,
                :red, :reset, :run_command, :updated, :waiting ]

  def self.options
    @@options ||= {}
  end

  def options
    self.class.options
  end

  HOOKS = Hash.new { |h,k| h[k] = [] }

  WINDOZE = /mswin|mingw/ =~ RbConfig::CONFIG['host_os']
  SEP = WINDOZE ? '&' : ';'

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
        require "pp"
        options[:debug] = true
      end

      opts.on "-v", "--verbose", "Be annoyingly verbose (debugs .autotest)." do
        options[:verbose] = true
      end

      opts.on "-q", "--quiet", "Be quiet." do
        options[:quiet] = true
      end

      opts.on("-r", "--rc CONF", String, "Override path to config file") do |o|
        options[:rc] = Array(o)
      end

      opts.on("-w", "--warnings", "Turn on ruby warnings") do
        $-w = true
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
  attr_accessor :extra_class_map
  attr_accessor :extra_files
  attr_accessor :failures
  attr_accessor :files_to_test # TODO: remove in favor of failures?
  attr_accessor :find_directories
  attr_accessor :find_order
  attr_accessor :interrupted
  attr_accessor :last_mtime
  attr_accessor :libs
  attr_accessor :output
  attr_accessor :prefix
  attr_accessor :sleep
  attr_accessor :tainted
  attr_accessor :test_mappings
  attr_accessor :testlib
  attr_accessor :test_prefix
  attr_accessor :wants_to_quit

  alias tainted? tainted

  ##
  # Initialize the instance and then load the user's .autotest file, if any.

  def initialize
    # these two are set directly because they're wrapped with
    # add/remove/clear accessor methods
    @exception_list = []
    @child = nil

    self.extra_class_map   = {}
    self.extra_files       = []
    self.failures          = Hash.new { |h,k| h[k] = Hash.new { |h2,k2| h2[k2] = [] } }
    self.files_to_test     = new_hash_of_arrays
    reset_find_order
    self.libs              = %w[. lib test].join(File::PATH_SEPARATOR)
    self.output            = $stderr
    self.prefix            = nil
    self.sleep             = 1
    self.test_mappings     = []
    self.test_prefix       = "gem 'minitest'"
    self.testlib           = "minitest/autorun" # TODO: rename

    specified_directories  = ARGV.reject { |arg| arg.start_with?("-") } # options are not directories
    self.find_directories  = specified_directories.empty? ? ['.'] : specified_directories

    # file in /lib -> run test in /test
    self.add_mapping(/^lib\/.*\.rb$/) do |filename, _|
      possible = File.basename(filename).gsub '_', '_?'
      files_matching %r%^test/.*#{possible}$%
    end

    # file in /test -> run it (ruby & rails styles)
    self.add_mapping(/^test.*\/(test_.*|.*_test)\.rb$/) do |filename, _|
      filename
    end

    default_configs = [File.expand_path('~/.autotest'), './.autotest']
    configs = options[:rc] || default_configs

    configs.each do |f|
      load f if File.exist? f
    end
  end

  def debug
    find_files_to_test

    puts "Known test files:"
    puts
    pp files_to_test.keys.sort

    class_map = self.class_map

    puts
    puts "Known class map:"
    puts
    pp class_map
  end

  def class_map
    class_map = Hash[*self.find_order.grep(/^test/).map { |f| # TODO: ugly
                       [path_to_classname(f), f]
                     }.flatten]
    class_map.merge! self.extra_class_map
    class_map
  end

  ##
  # Repeatedly run failed tests, then all tests, then wait for changes
  # and carry on until killed.

  def run
    hook :initialize
    hook :post_initialize

    require "minitest/server"
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
        else
          hook :all_good
        end
        wait_for_changes
      rescue Interrupt
        break if wants_to_quit
        reset
      end
    end
    hook :quit
    puts
  rescue Exception => err
    hook(:died, err) or raise err
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

    hook :run_command, cmd

    puts cmd unless options[:quiet]

    system cmd

    hook :ran_command
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
        unless hook :interrupt then
          puts "Interrupt a second time to quit"
          self.interrupted = true
          Kernel.sleep 1.5
        end
        raise Interrupt, nil # let the run loop catch it
      end
    end
  end

  ##
  # Installs a sigquit handler

  def add_sigquit_handler
    trap 'QUIT' do
      restart
    end
  end

  def restart
    Process.kill "KILL", @child if @child

    cmd = [$0, *options[:args]]

    index = $LOAD_PATH.index RbConfig::CONFIG["sitelibdir"]

    if index then
      extra = $LOAD_PATH[0...index]
      cmd = [Gem.ruby, "-I", extra.join(":")] + cmd
    end

    puts cmd.join(" ") if options[:verbose]

    exec(*cmd)
  end

  ##
  # If there are no files left to test (because they've all passed),
  # then all is good.

  def all_good
    failures.empty?
  end

  ##
  # Convert a path in a string, s, into a class name, changing
  # underscores to CamelCase, etc.

  def path_to_classname s
    sep = File::SEPARATOR
    f = s.sub(/^test#{sep}/, '').sub(/\.rb$/, '').split sep
    f = f.map { |path| path.split(/_|(\d+)/).map { |seg| seg.capitalize }.join }
    f = f.map { |path| path =~ /^Test/ ? path : "Test#{path}"  }

    f.join '::'
  end

  ##
  # Find the files to process, ignoring temporary files, source
  # configuration management files, etc., and return a Hash mapping
  # filename to modification time.

  def find_files
    result = {}
    targets = self.find_directories + self.extra_files
    reset_find_order

    targets.each do |target|
      order = []
      Find.find target do |f|
        Find.prune if f =~ self.exceptions
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

      hook :updated, updated
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
    if options[:debug] then
      puts "Files to test:"
      puts
      pp files_to_test
      puts
    end

    cmds = []
    full, partial = reorder(failures).partition { |k,v| v.empty? }

    unless full.empty? then
      classes = full.map {|k,v| k}.flatten.uniq
      classes.unshift testlib
      classes = classes.join " "
      cmds << "#{ruby_cmd} -e \"#{test_prefix}; %w[#{classes}].each { |f| require f }\" -- --server #{$$}"
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

      cmds << "#{ruby_cmd} -e '#{loader}' -- -a #{$$} -n '/#{re}/'"
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

    hook :all_good if all_good
  end

  ##
  # Clear all state information about test failures and whether
  # interrupts will kill autotest.

  def reset
    self.files_to_test.clear
    reset_find_order
    self.failures.clear

    self.interrupted   = false
    self.last_mtime    = T0
    self.tainted       = false
    self.wants_to_quit = false

    hook :reset
  end

  def reset_find_order
    self.find_order = []
    self.known_files = nil
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
    hook :waiting
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

  ##
  # Removed a file mapping matching +regexp+.

  def remove_mapping regexp
    @test_mappings.delete_if do |k,v|
      k == regexp
    end
    nil
  end

  ##
  # Clears all file mappings. This is DANGEROUS as it entirely
  # disables autotest. You must add at least one file mapping that
  # does a good job of rerunning appropriate tests.

  def clear_mappings
    @test_mappings.clear
    nil
  end

  ############################################################
  # Exceptions:

  ##
  # Adds +regexp+ to the list of exceptions for find_file. This must
  # be called _before_ the exceptions are compiled.

  def add_exception regexp
    raise "exceptions already compiled" if defined? @exceptions

    @exception_list << regexp
    nil
  end

  ##
  # Removes +regexp+ to the list of exceptions for find_file. This
  # must be called _before_ the exceptions are compiled.

  def remove_exception regexp
    raise "exceptions already compiled" if defined? @exceptions
    @exception_list.delete regexp
    nil
  end

  ##
  # Clears the list of exceptions for find_file. This must be called
  # _before_ the exceptions are compiled.

  def clear_exceptions
    raise "exceptions already compiled" if defined? @exceptions
    @exception_list.clear
    nil
  end

  ##
  # Return a compiled regexp of exceptions for find_files or nil if no
  # filtering should take place. This regexp is generated from
  # +exception_list+.

  def exceptions
    unless defined? @exceptions then
      @exceptions = if @exception_list.empty? then
                      nil
                    else
                      Regexp.union(*@exception_list)
                    end
    end

    @exceptions
  end

  ############################################################
  # Hooks:

  ##
  # Call the event hook named +name+, passing in optional args
  # depending on the hook itself.
  #
  # Returns false if no hook handled the event.
  #
  # === Hook Writers!
  #
  # This executes all registered hooks <em>until one returns truthy</em>.
  # Pay attention to the return value of your block!

  def hook name, *args
    deprecated = {
      # none currently
    }

    if deprecated[name] and not HOOKS[name].empty? then
      warn "hook #{name} has been deprecated, use #{deprecated[name]}"
    end

    HOOKS[name].any? { |plugin| plugin[self, *args] }
  end

  ##
  # Add the supplied block to the available hooks, with the given
  # name.

  def self.add_hook name, &block
    HOOKS[name] << block
  end

  add_hook :died do |at, err|
    warn "Unhandled exception: #{err}"
    warn err.backtrace.join("\n  ")
    warn "Quitting"
  end

  ############################################################
  # Server Methods:

  def minitest_start
    self.failures.clear
  end

  def minitest_result file, klass, method, fails, assertions, time
    fails.reject! { |fail| Minitest::Skip === fail }

    unless fails.empty?
      self.tainted = true
      self.failures[file][klass] << method
    end
  end
end
