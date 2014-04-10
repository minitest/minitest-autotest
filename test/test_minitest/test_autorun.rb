require "minitest/autorun"

class FooTest < Minitest::Test
  def test_passes
    assert true
  end

  def test_fails
    flunk
  end

  def test_error
    raise
  end
end
