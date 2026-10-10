defmodule Midgard.CLI.Config do
  @moduledoc "Reads the trusted, required `midgard.config.exs` build configuration."

  def load(root \\ File.cwd!()) do
    path = Path.join(root, "midgard.config.exs")

    with {:ok, _} <- File.stat(path),
         {config, _bindings} <- Code.eval_file(path),
         :ok <- validate(config) do
      {:ok, config}
    else
      {:error, :enoent} -> {:error, "midgard.config.exs is required in the project root"}
      {:error, reason} -> {:error, "cannot read #{path}: #{inspect(reason)}"}
      _ -> {:error, "midgard.config.exs must return [entry: MyWorker, target: :libbeam]"}
    end
  rescue
    error -> {:error, "midgard.config.exs failed: #{Exception.message(error)}"}
  end

  def entry(config), do: config[:entry]

  defp validate(config) when is_list(config) do
    entry = config[:entry]

    if Keyword.keyword?(config) and Keyword.keys(config) -- [:entry, :target] == [] and
         is_atom(entry) and entry not in [nil, true, false] and
         config[:target] == :libbeam do
      :ok
    else
      :error
    end
  end

  defp validate(_), do: :error
end
