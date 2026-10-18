defmodule Packer.RuntimeToolchain do
  @moduledoc false

  @elixir_version "1.21.0-dev"
  @otp_release "29"
  @elixir_revision "13299af2b91a6aff7e430f25849f586c02b3231f"
  @accepted_revisions ["", @elixir_revision]

  def validate_elixir(build_info \\ System.build_info())

  def validate_elixir(build_info) when is_map(build_info) do
    version = Map.get(build_info, :version)
    otp_release = Map.get(build_info, :otp_release)
    revision = Map.get(build_info, :revision)

    if version == @elixir_version and otp_release == @otp_release and
         revision in @accepted_revisions do
      :ok
    else
      {:error,
       "Elixir worker builds require Elixir #{@elixir_version} from runtime revision " <>
         "#{@elixir_revision} on OTP #{@otp_release}; got #{Map.get(build_info, :build, inspect(build_info))}"}
    end
  end

  def validate_elixir(_), do: {:error, "cannot identify the Elixir runtime toolchain"}
end
