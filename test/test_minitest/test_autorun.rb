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
