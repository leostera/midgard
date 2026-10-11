defmodule Packer.Dependencies do
  @moduledoc "Collects compiled pure Erlang and Elixir Mix dependency BEAMs without loading them."

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
    if Mix.Dep.ok?(dep) do
      root = dep.opts[:dest]
      ebin = Path.join(dep.opts[:build], "ebin")
      Packer.BeamFiles.collect(root, ebin)
    else
      {:error, "dependency is not resolved; run mix deps.get"}
    end
  end
end
