defmodule Libbeam.PortProtocol do
  @moduledoc false
  @version 1
  @max_frame 32 * 1024 * 1024
  @operations %{create: 1, load: 2, call: 3, stop: 4, shutdown: 5}

  def encode(id, operation, payload)
      when is_integer(id) and id in 1..18_446_744_073_709_551_615 and is_binary(payload) do
    case Map.fetch(@operations, operation) do
      {:ok, opcode} when byte_size(payload) + 10 <= @max_frame ->
        {:ok, <<@version, id::64, opcode, payload::binary>>}

      {:ok, _} ->
        {:error, "Port request exceeds 32 MiB"}

      :error ->
        {:error, "unknown Port operation"}
    end
  end

  def encode(_, _, _), do: {:error, "invalid Port request"}

  def decode(<<@version, id::64, 0, payload::binary>>), do: {:ok, id, {:ok, payload}}

  def decode(<<@version, id::64, 1, code::16, length::16, message::binary-size(length)>>),
    do: {:ok, id, {:error, %Libbeam.Error{code: code, message: message}}}

  def decode(_), do: {:error, "invalid Port response"}

  def load_payload(isolate_id, beams, options)
      when is_integer(isolate_id) and isolate_id in 1..18_446_744_073_709_551_615 and
             is_list(beams) and is_list(options) do
    if Keyword.keyword?(options) and
         Keyword.keys(options) -- [:defer_denied_nif] == [] and
         Keyword.get(options, :defer_denied_nif, false) in [true, false] and
         length(beams) in 1..512 and Enum.all?(beams, &is_binary/1) do
      policy = if Keyword.get(options, :defer_denied_nif, false), do: 1, else: 0

      payload = [
        <<isolate_id::64, length(beams)::32, policy>>,
        Enum.map(beams, &<<byte_size(&1)::32, &1::binary>>)
      ]

      if IO.iodata_length(payload) + 10 <= @max_frame,
        do: {:ok, IO.iodata_to_binary(payload)},
        else: {:error, "module group exceeds Port frame bound"}
    else
      {:error, "expected 1..512 BEAM binaries and a boolean on_load policy"}
    end
  end

  def load_payload(_, _, _), do: {:error, "invalid module group"}

  def call_payload(isolate_id, module, function, input)
      when is_integer(isolate_id) and isolate_id in 1..18_446_744_073_709_551_615 and
             is_binary(module) and
             is_binary(function) and is_binary(input) and byte_size(module) in 1..255 and
             byte_size(function) in 1..255 and byte_size(input) <= 65_536 do
    {:ok,
     <<isolate_id::64, byte_size(module)::16, module::binary, byte_size(function)::16,
       function::binary, byte_size(input)::32, input::binary>>}
  end

  def call_payload(_, _, _, _), do: {:error, "invalid module, function or call bytes"}
end
