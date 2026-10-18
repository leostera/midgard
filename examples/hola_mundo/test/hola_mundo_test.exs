defmodule HolaMundoTest do
  use ExUnit.Case, async: true

  test "handles a named hello route through the binary entrypoint" do
    request = Midgard.Request.new("GET", "/hello/joe")
    assert HolaMundo.handle_request(request) == {200, "hello, joe!"}

    assert {:ok, bytes} = Midgard.Protocol.request(request)

    assert {:ok, {200, "hello, joe!"}} =
             bytes |> HolaMundo.__midgard_call__() |> Midgard.Protocol.decode_response()
  end

  test "responds to routes without a name with 404" do
    for path <- ["/", "/hello", "/missing"] do
      assert HolaMundo.handle_request(Midgard.Request.new("GET", path)) ==
               {404, "Not found\n"}
    end
  end
end
