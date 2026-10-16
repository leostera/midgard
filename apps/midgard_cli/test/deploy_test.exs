defmodule Midgard.CLI.DeployTest do
  use ExUnit.Case, async: true

  test "custom remote hosts still require their own deployment credentials" do
    assert_raise Mix.Error,
                 "Set MIDGARD_DEPLOY_TOKEN before deploying to a custom remote host",
                 fn -> Mix.Tasks.Midgard.Deploy.run(["--endpoint", "https://example.net"]) end
  end
end
