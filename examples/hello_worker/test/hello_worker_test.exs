defmodule HelloWorkerTest do
  use ExUnit.Case, async: false
  alias Midgard.{Protocol, Request}

  test "greets using the request query string" do
    request = %Request{method: "GET", path: "/hello", query_string: "name=Midgard"}
    assert HelloWorker.handle_request(request) == {200, "Hello, Midgard!\n"}
    assert {:ok, bytes} = Protocol.request(request)

    assert {:ok, {200, "Hello, Midgard!\n"}} =
             bytes |> HelloWorker.__midgard_call__() |> Protocol.decode_response()
  end

  test "Packer includes both project modules, Jason and the worker SDK as exact-name BEAMs" do
    assert {:ok, output} = Packer.pack(entry: HelloWorker, output: "hello_worker.midgard")
    assert {:ok, manifest} = Packer.Verifier.verify(output)
    names = Enum.map(manifest["modules"], & &1["name"])
    assert "Elixir.HelloWorker" in names
    assert "Elixir.HelloWorker.Greeter" in names
    assert "Elixir.Jason" in names
    assert "Elixir.Midgard.Protocol" in names
    assert "Elixir.Midgard.Request" in names

    assert manifest["entrypoint"] == %{
             "module" => "Elixir.HelloWorker",
             "function" => "__midgard_call__",
             "arity" => 1,
             "protocol" => "midgard.bytes.v1"
           }

    assert manifest["required_capabilities"] == []
    assert manifest["target"]["execution"] == "not_verified"
    assert {:ok, report} = Packer.Profile.report(output)
    assert report["known_unsupported_current_core"] != []
  end

  test "uses the pure Elixir Jason dependency for JSON requests" do
    request = %Request{method: "POST", path: "/json", body: ~s({"name":"Midgard"})}
    assert HelloWorker.handle_request(request) == {200, ~s({"greeting":"Hello, Midgard!\\n"})}
  end

  test "echoes binary bodies and handles unknown routes" do
    request = %Request{method: "POST", path: "/echo", body: <<0, 255>>}
    assert HelloWorker.handle_request(request) == {200, <<0, 255>>}
    assert HelloWorker.handle_request(Request.new("GET", "/missing")) == {404, "Not found\n"}
  end
end
