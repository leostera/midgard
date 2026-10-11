defmodule Packer.BeamFiles do
  @moduledoc "Reads compiled BEAMs from a trusted local application's ebin directory."

  def collect(root, ebin) do
    erlang_sources = Path.wildcard(Path.join(root, "src/**/*.erl"))
    elixir_sources = Path.wildcard(Path.join(root, "lib/**/*.ex"))
    beams = Path.wildcard(Path.join(ebin, "*.beam")) |> Enum.sort()

    cond do
      File.dir?(Path.join(root, "c_src")) or File.dir?(Path.join(root, "native")) or
        nonempty_priv?(root) or Path.wildcard(Path.join(root, "lib/**/*.{erl,exs}")) != [] ->
        {:error, "native code, unsupported source layout or unpackaged priv resources"}

      beams == [] or erlang_sources ++ elixir_sources == [] ->
        {:error, "expected compiled Erlang or Elixir sources and BEAMs; run the project compiler"}

      Enum.any?(erlang_sources, fn source ->
        not File.regular?(Path.join(ebin, Path.basename(source, ".erl") <> ".beam"))
      end) ->
        {:error, "an Erlang source module has no matching compiled BEAM"}

      true ->
        read_beams(beams)
    end
  end

  defp nonempty_priv?(root) do
    path = Path.join(root, "priv")
    File.dir?(path) and File.ls!(path) != []
  end

  defp read_beams(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case File.read(path) do
        {:ok, bytes} -> {:cont, {:ok, [{Path.basename(path, ".beam"), bytes} | acc]}}
        {:error, reason} -> {:halt, {:error, "cannot read #{path}: #{inspect(reason)}"}}
      end
    end)
    |> case do
      {:ok, beams} -> {:ok, Enum.reverse(beams)}
      error -> error
    end
  end
end
