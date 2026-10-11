defmodule MixedWorkerTest do
  use ExUnit.Case, async: true

  test "Elixir delegates to an exact-name Erlang module" do
    assert MixedWorker.__midgard_call__(<<0, 255>>) == <<0, 255>>
  end
end
