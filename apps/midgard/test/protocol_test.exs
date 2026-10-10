defmodule Midgard.ProtocolTest do
  use ExUnit.Case, async: true

  alias Midgard.{Protocol, Request}

  defmodule Worker do
    use Midgard.Worker

    @impl true
    def handle_request(%Request{body: "raise"}), do: raise("failure")
    def handle_request(%Request{body: "bad"}), do: {:wrong, %{unsafe: true}}
    def handle_request(%Request{body: body}), do: {200, body}
  end

  test "bounded request and response binary entrypoint" do
    request = %Request{
      method: "POST",
      path: "/hello",
      query_string: "x=1",
      headers: [{"x-id", "one"}, {"x-id", "two"}],
      body: <<0, 255>>
    }

    assert {:ok, bytes} = Protocol.request(request)
    assert {:ok, ^request} = Protocol.decode_request(bytes)

    assert {:ok, {200, <<0, 255>>}} =
             bytes |> Worker.__midgard_call__() |> Protocol.decode_response()
  end

  test "rejects malformed and oversized frames without deserializing terms" do
    assert {:error, :invalid_request} = Protocol.decode_request(<<1, 0>>)
    assert {:error, :invalid_request} = Protocol.decode_request(<<1, 0::size(65_536 * 8)>>)

    assert {:error, :invalid_request} =
             Protocol.request(%Request{method: "GET", path: "/" <> String.duplicate("x", 2050)})

    assert {:error, :invalid_request} =
             Protocol.request(%Request{method: "GET", path: "/", headers: [{"X-Invalid", "yes"}]})

    assert {:error, :invalid_request} =
             Protocol.request(%Request{
               method: "GET",
               path: "/",
               body: String.duplicate("a", 32_769)
             })

    assert {:ok, {400, _}} = <<1, 0>> |> Worker.__midgard_call__() |> Protocol.decode_response()
  end

  test "invalid worker returns and exceptions become bounded error responses" do
    for {body, status} <- [{"bad", 500}, {"raise", 500}] do
      {:ok, bytes} = Protocol.request(%Request{method: "GET", path: "/", body: body})

      assert {:ok, {^status, "worker error\n"}} =
               bytes |> Worker.__midgard_call__() |> Protocol.decode_response()
    end

    assert {:error, :invalid_response} = Protocol.response({200, String.duplicate("x", 65_532)})
    assert {:error, :invalid_response} = Protocol.decode_response(<<2, 200::16, 2::16, "a">>)
  end
end
