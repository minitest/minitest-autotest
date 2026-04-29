require "minitest/autorun"

class Foo
  def raises
    raise "blah"
  end
end

class FooTest < Minitest::Test
  def test_pass
    assert true
  end

  def test_skip
    skip "nope"
  end

  if ENV["BAD"] then # allows it to pass my CI but easy to demo
    def test_fail
      flunk "write tests or I will kneecap you"
    end

    def test_error
      Foo.new.raises
    end

    def assert_bad_thingy
      Foo.new.raises
    end

    def test_indirect_error
      assert_bad_thingy
    end
  end
end

require "autotest"
class TestAutotest < Minitest::Test
  class AutotestSUT < ::Autotest
    def run = self # don't actually run
  end

  def test_cls_run
    x = nil
    assert_output "" do
      x = AutotestSUT.run %w[ --rc dot_autotest ]
    end

    assert_instance_of AutotestSUT, x
    assert_equal ["dot_autotest"], x.options[:rc]

    x.last_mtime = Time.now
    assert_nil x.find_files_to_test

    x.last_mtime = Time.at 0
    refute_nil x.find_files_to_test

    assert_includes x.files_to_test, "test/test_minitest/test_autorun.rb"
  end
end
