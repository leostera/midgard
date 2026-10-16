defmodule HolaMundoTest do
  use ExUnit.Case, async: true

  test "handles the hello route through the provisional binary entrypoint" do
    request = Midgard.Request.new("GET", "/hello")
    assert HolaMundo.handle_request(request) == {200, "Hello from HolaMundo!\n"}

    assert HolaMundo.handle_request(Midgard.Request.new("GET", "/")) ==
             {200, "Hello from HolaMundo!\n"}

    assert {:ok, bytes} = Midgard.Protocol.request(request)

    assert {:ok, {200, "Hello from HolaMundo!\n"}} =
             bytes |> HolaMundo.__midgard_call__() |> Midgard.Protocol.decode_response()
  end

  test "responds to unknown routes" do
    assert HolaMundo.handle_request(Midgard.Request.new("GET", "/missing")) ==
             {404, "Not found\n"}
  end
end
