# require "./at_plugin.rb"

require "minitest/autorun"

class GoodTest < Minitest::Test
  def test_passes
    assert true
  end
end
