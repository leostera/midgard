defmodule Midgard.Request do
  @moduledoc """
  The Elixir worker API's HTTP-shaped request decoded from a bounded binary
  invocation. No host resource, PID, or guest filesystem handle is part of
  this struct.

  `query_string` excludes the leading `?`. Headers are lowercase `{name, value}`
  pairs and preserve duplicate names. This API is tested on ordinary OTP; its
  complete dependency closure has not run in libbeam.
  """

  @enforce_keys [:method, :path]
  defstruct [:method, :path, query_string: "", headers: [], body: ""]

  @type t :: %__MODULE__{
          method: binary(),
          path: binary(),
          query_string: binary(),
          headers: [{binary(), binary()}],
          body: binary()
        }

  def new(method, path), do: %__MODULE__{method: method, path: path}

  @doc "Returns the first value of a case-insensitive header name, or nil."
  def header(%__MODULE__{headers: headers}, name) when is_binary(name) do
    downcased = String.downcase(name)

    case Enum.find(headers, fn {key, _value} -> key == downcased end) do
      {_key, value} -> value
      nil -> nil
    end
  end
end
