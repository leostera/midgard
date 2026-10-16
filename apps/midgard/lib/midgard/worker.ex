defmodule Midgard.Worker do
  @moduledoc """
  Elixir worker behaviour and binary entrypoint for a future libbeam host.

  `use Midgard.Worker` generates `__midgard_call__/1`: a binary-to-binary,
  arity-one function. It decodes a bounded request and invokes the Elixir
  `handle_request/1` callback. The artifact/byte entrypoint does not require
  Erlang or Gleam workers to use this Elixir API. This SDK is tested on ordinary
  OTP; its complete dependency closure has not executed in libbeam.
  """

  @callback handle_request(Midgard.Request.t()) :: {integer(), binary()}

  defmacro __using__(_options) do
    quote do
      @behaviour Midgard.Worker

      @doc false
      def __midgard_call__(bytes) when is_binary(bytes) do
        try do
          case Midgard.Protocol.decode_request(bytes) do
            {:ok, request} ->
              case Midgard.Protocol.response(handle_request(request)) do
                {:ok, response} -> response
                _ -> Midgard.Worker.error_response(500)
              end

            _ ->
              Midgard.Worker.error_response(400)
          end
        rescue
          _ -> Midgard.Worker.error_response(500)
        end
      end
    end
  end

  @doc false
  def error_response(status) do
    {:ok, response} = Midgard.Protocol.response({status, "worker error\n"})
    response
  end
end
