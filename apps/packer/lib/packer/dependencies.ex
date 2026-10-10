defmodule Packer.Dependencies do
  @moduledoc "Collects compiled pure-Elixir Mix dependency BEAMs without loading them."

  def collect do
    Mix.Dep.load_and_cache()
    |> Enum.reject(&(&1.opts[:runtime] == false))
    |> Enum.sort_by(& &1.app)
    |> Enum.reduce_while({:ok, []}, fn dep, {:ok, acc} ->
      case compiled_modules(dep) do
        {:ok, beams} ->
          record = %{
            app: Atom.to_string(dep.app),
            version: to_string(dep.status |> elem(1)),
            beams: beams
          }

          {:cont, {:ok, [record | acc]}}

        {:error, reason} ->
          {:halt, {:error, "#{dep.app}: #{reason}"}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp compiled_modules(dep) do
    root = dep.opts[:dest]
    ebin = Path.join(dep.opts[:build], "ebin")
    sources = Path.wildcard(Path.join(root, "lib/**/*.ex"))
    beams = Path.wildcard(Path.join(ebin, "Elixir.*.beam")) |> Enum.sort()

    cond do
      not Mix.Dep.ok?(dep) ->
        {:error, "dependency is not resolved; run mix deps.get"}

      sources == [] or beams == [] ->
        {:error, "expected compiled pure-Elixir source; run mix compile"}

      File.dir?(Path.join(root, "c_src")) or File.dir?(Path.join(root, "native")) or
        Path.wildcard(Path.join(root, "priv/**/*.{so,dylib,dll}")) != [] or
        Path.wildcard(Path.join(root, "lib/**/*.{erl,exs}")) != [] or
          Path.wildcard(Path.join(ebin, "*.beam")) != beams ->
        {:error, "native or non-Elixir source is not supported"}

      Enum.any?(sources, fn path ->
        File.read!(path) |> String.contains?([":erlang.load_nif", "erl_nif", "@on_load"])
      end) ->
        {:error, "native loading hooks are not supported"}

      true ->
        read_beams(beams)
    end
  end

  defp read_beams(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case File.read(path) do
        {:ok, bytes} ->
          name = Path.basename(path, ".beam")
          {:cont, {:ok, [{name, bytes} | acc]}}

        {:error, reason} ->
          {:halt, {:error, "cannot read #{path}: #{inspect(reason)}"}}
      end
    end)
    |> case do
      {:ok, beams} -> {:ok, Enum.reverse(beams)}
      error -> error
    end
  end
end
