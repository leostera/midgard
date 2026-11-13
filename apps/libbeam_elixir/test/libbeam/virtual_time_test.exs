defmodule Midgard.LibbeamAssertionsTest do
  use Midgard.Test

  test "Elixir assertion passes inside a fresh Isolate" do
    assert 2 + 2 == 4
  end
end
