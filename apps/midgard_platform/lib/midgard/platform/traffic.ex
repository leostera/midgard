defmodule Midgard.Platform.Traffic do
  @moduledoc """
  Bounded, durable local per-worker invocation totals. A write is atomic and
  serialized by Workspace; a malformed file is reported, never shown as zero.
  """
  @maximum 9_223_372_036_854_775_807

  def read(root, slug) do
    path = path(root, slug)

    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, %{invocations: 0, last_invoked_at: nil}}

      {:ok, %{type: :regular, size: size}} when size in 3..64 ->
        with {:ok, bytes} <- File.read(path), do: parse(bytes)

      _ ->
        {:error, :invalid_traffic_file}
    end
  end

  def record(root, slug) do
    with {:ok, %{invocations: count}} <- read(root, slug),
         true <- count < @maximum do
      timestamp = System.system_time(:millisecond)
      path = path(root, slug)
      temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
      bytes = "#{count + 1}\t#{timestamp}\n"

      case File.write(temporary, bytes) do
        :ok ->
          case File.rename(temporary, path) do
            :ok ->
              :ok

            error ->
              File.rm(temporary)
              error
          end

        error ->
          error
      end
    else
      false -> {:error, :counter_exhausted}
      error -> error
    end
  end

  defp parse(bytes) do
    case String.split(bytes, ["\t", "\n"], trim: true) do
      [count, timestamp] ->
        with {n, ""} <- Integer.parse(count),
             {ms, ""} <- Integer.parse(timestamp),
             true <- n in 1..@maximum and ms in 1..9_999_999_999_999 do
          {:ok, %{invocations: n, last_invoked_at: ms}}
        else
          _ -> {:error, :invalid_traffic_file}
        end

      _ ->
        {:error, :invalid_traffic_file}
    end
  end

  defp path(root, slug), do: Path.join([root, "workers", slug, "traffic.tsv"])
end
