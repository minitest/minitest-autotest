# -*- ruby -*-

require "rubygems"
require "hoe"

# Hoe.plugin :isolate
Hoe.plugin :seattlerb
Hoe.plugin :rdoc

Hoe.spec "minitest-autotest" do
  developer "Ryan Davis", "ryand-ruby@zenspider.com"
  license "MIT"

  dependency "minitest", "~> 6.0"
end

desc "update example_dot_autotest.rb with all possible constants"
task :update do
  system "p4 edit example_dot_autotest.rb"
  File.open "example_dot_autotest.rb", "w" do |f|
    f.puts "# -*- ruby -*-"
    f.puts
    Dir.chdir "lib" do
      Dir["autotest/*.rb"].sort.each do |s|
        next if s =~ /rails|discover/
        f.puts "# require '#{s[0..-4]}'"
      end
    end

    f.puts

    Dir["lib/autotest/*.rb"].sort.each do |file|
      file = File.read(file)
      m = file[/module.*/].split(/ /).last rescue nil
      next unless m

      dirty = false

      file.lines.grep(/def[^(]+=/).each do |setter|
        dirty = true
        setter = setter.sub(/^ *def self\./, '').sub(/\s*=\s*/, ' = ')
        f.puts "# #{m}.#{setter}"
      end

      f.puts if dirty
    end

    File.foreach("lib/autotest.rb") do |line|
      next unless line =~ /hook (:\w+)/
      name = $1

      f.puts "# Autotest.add_hook #{name} do |at|"
      f.puts "#   ... do stuff for #{name} hook ..."
      f.puts "# end"
      f.puts
    end
  end
  system "p4 diff -du example_dot_autotest.rb"
end

# vim: syntax=ruby
