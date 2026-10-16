defmodule Midgard.CLI.DeployTest do
  use ExUnit.Case, async: true

  test "public deployment reports the closed route instead of asking for a token" do
    assert_raise Mix.Error,
                 "Public deployment is not enabled yet on midgard.leostera.dev; a token will not fix this",
                 fn ->
                   Mix.Tasks.Midgard.Deploy.run([
                     "--endpoint",
                     "https://midgard.leostera.dev"
                   ])
                 end
  end
end
