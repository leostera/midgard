defmodule Packer.RuntimeToolchainTest do
  use ExUnit.Case, async: true

  alias Packer.RuntimeToolchain

  test "accepts the exact pinned Elixir runtime toolchain" do
    pinned = %{
      version: "1.21.0-dev",
      otp_release: "29",
      revision: "13299af2b91a6aff7e430f25849f586c02b3231f"
    }

    assert :ok = RuntimeToolchain.validate_elixir(pinned)
    assert :ok = RuntimeToolchain.validate_elixir(%{pinned | revision: ""})
  end

  test "rejects a different Elixir source revision before packaging" do
    incompatible = %{
      version: "1.21.0-dev",
      otp_release: "29",
      revision: "eaa0e70"
    }

    assert {:error, message} = RuntimeToolchain.validate_elixir(incompatible)
    assert message =~ "runtime revision 13299af2b91a6aff7e430f25849f586c02b3231f"
    assert message =~ "eaa0e70"
  end
end
