require 'autotest'

module Autotest::Rails
  Autotest.add_hook :initialize do |at|
    at.add_exception %r%^\./(?:db|doc|log|public|script|tmp|vendor|app/assets)%

    at.clear_mappings

    at.add_mapping %r%^lib/(.*)\.rb$% do |_, m|
      at.files_matching %r%^test/(lib|unit/lib)/#{m[1]}.*_test.rb$%
      # TODO: (unit|functional|integration) maybe?
    end

    at.add_mapping %r%^test/fixtures/(.*)s.yml% do |_, m|
      at.files_matching %r%^test/(models|controllers|views|unit|functional)/#{m[1]}.*_test.rb$%
    end

    at.add_mapping %r%^test/.*_test\.rb$% do |filename, _|
      filename
    end

    at.add_mapping %r%^app/models/(.*)\.rb$% do |_, m|
      at.files_matching %r%^test/(models|unit)/#{m[1]}.*_test.rb$%
    end

    at.add_mapping %r%^app/helpers/(.*)_helper.rb% do |_, m|
      if m[1] == "application" then
        at.files_matching %r%^test/(helpers|controllers|views|unit/helpers/functional)/.*_test\.rb$%
      else
        at.files_matching %r%^test/(helpers|controllers|views|unit/helpers/functional)/#{m[1]}.*_test.rb$%
      end
    end

    at.add_mapping %r%^app/views/(.*)/% do |_, m|
      at.files_matching %r%^test/(controllers|views|functional)/#{m[1]}.*_test.rb$%
    end

    at.add_mapping %r%^app/controllers/(.*)\.rb$% do |_, m|
      if m[1] == "application" then
        at.files_matching %r%^test/(controllers|views|functional)/.*_test\.rb$%
      else
        at.files_matching %r%^test/(controllers|views|functional)/#{m[1]}.*_test.rb$%
      end
    end

    at.add_mapping %r%^app/views/layouts/% do
      "test/views/layouts_view_test.rb"
    end

    at.add_mapping %r%^test/test_helper.rb|config/((boot|environment(s/test)?).rb|database.yml|routes.rb)% do
      at.files_matching %r%^test/(models|controllers|views|unit|functional)/.*_test.rb$%
    end
  end
end

class Autotest
  alias old_path_to_classname path_to_classname

  # Convert the pathname s to the name of class.
  def path_to_classname s
    sep = File::SEPARATOR
    f = s.sub(/^test#{sep}((\w+)#{sep})?/, '').sub(/\.rb$/, '').split sep
    f = f.map { |path| path.split(/_|(\d+)/).map { |seg| seg.capitalize }.join }
    f = f.map { |path| path =~ /Test$/ ? path : "#{path}Test"  }
    f.join '::'
  end
end
