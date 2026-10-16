defmodule Packer.ShipmentUploadTest do
  use ExUnit.Case, async: true
  alias Packer.ShipmentUpload

  test "round trips exact manifest and BEAM bytes without interpreting uploaded code" do
    manifest =
      :json.encode(%{
        "application" => "sample",
        "modules" => [%{"name" => "Elixir.Sample", "path" => "modules/Elixir.Sample.beam"}]
      })
      |> IO.iodata_to_binary()

    original = %ShipmentUpload{
      application: "sample",
      manifest: manifest,
      modules: [{"Elixir.Sample", <<0, 1, 255>>}]
    }

    assert {:ok, ^original} = original |> ShipmentUpload.encode() |> ShipmentUpload.parse()
  end

  test "rejects corrupt framing, path traversal and duplicate module names" do
    manifest =
      :json.encode(%{"application" => "sample", "modules" => []}) |> IO.iodata_to_binary()

    valid = %ShipmentUpload{
      application: "sample",
      manifest: manifest,
      modules: [{"Elixir.Sample", <<1>>}]
    }

    wire = ShipmentUpload.encode(valid)
    assert {:error, _} = ShipmentUpload.parse(wire <> <<0>>)
    assert {:error, _} = ShipmentUpload.parse(binary_part(wire, 0, byte_size(wire) - 1))
    assert {:error, _} = ShipmentUpload.parse(:binary.copy("x", ShipmentUpload.max_wire() + 1))

    malformed = %ShipmentUpload{valid | modules: [{"../escape", <<1>>}]}
    assert {:error, _} = malformed |> ShipmentUpload.encode() |> ShipmentUpload.parse()

    repeated = %ShipmentUpload{
      valid
      | modules: [{"Elixir.Sample", <<1>>}, {"Elixir.Sample", <<2>>}]
    }

    assert {:error, _} = repeated |> ShipmentUpload.encode() |> ShipmentUpload.parse()
  end
end
