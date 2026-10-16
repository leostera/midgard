defmodule Packer.Artifact do
  @moduledoc "Writes a versioned directory of exact-name BEAM files and a canonical manifest."

  @max_modules 512
  @max_total 32_000_000
  @max_beam 2_000_000

  def build(output, app, entry, modules, dependencies, options \\ [])

  def build(output, app, entry, modules, dependencies, options)
      when is_binary(output) and is_binary(app) and is_binary(entry) and
             is_list(modules) and is_list(dependencies) and is_list(options) do
    output = Path.expand(output)

    with :ok <- validate_modules(modules),
         :ok <- validate_dependencies(dependencies, options),
         {:ok, manifest} <- manifest(app, entry, modules, dependencies, options),
         :ok <- prepare_destination(output) do
      stage = output <> ".tmp-#{System.unique_integer([:positive])}"

      try do
        File.mkdir_p!(Path.join(stage, "modules"))

        Enum.each(modules, fn %{name: name, bytes: bytes} ->
          File.write!(Path.join(stage, "modules/#{name}.beam"), bytes)
        end)

        File.write!(Path.join(stage, "manifest.json"), Packer.JSON.encode(manifest) <> "\n")

        with {:ok, _manifest} <- Packer.Verifier.verify(stage),
             {:ok, _profile} <- Packer.Profile.report(stage),
             :ok <- publish(stage, output) do
          {:ok, output}
        end
      rescue
        error -> {:error, "could not write artifact: #{Exception.message(error)}"}
      after
        File.rm_rf(stage)
      end
    end
  end

  def build(_, _, _, _, _, _), do: {:error, "invalid artifact arguments"}

  defp validate_modules(modules) do
    cond do
      modules == [] or length(modules) > @max_modules ->
        {:error, "module count exceeds artifact limits"}

      not Enum.all?(modules, fn
        %{name: name, owner: owner, bytes: bytes} ->
          is_binary(name) and is_binary(owner) and is_binary(bytes) and
              byte_size(bytes) in 1..@max_beam

        _ ->
          false
      end) ->
        {:error, "invalid or oversized BEAM module"}

      true ->
        names = Enum.map(modules, & &1.name)
        size = Enum.reduce(modules, 0, fn module, acc -> acc + byte_size(module.bytes) end)

        cond do
          length(Enum.uniq(names)) != length(names) -> {:error, "duplicate BEAM module names"}
          size > @max_total -> {:error, "artifact BEAMs exceed 32 MB"}
          true -> :ok
        end
    end
  end

  defp validate_dependencies(dependencies, options) do
    valid =
      Enum.all?(dependencies, fn
        %{app: app, version: version, modules: modules} ->
          is_binary(app) and is_binary(version) and is_list(modules) and
            Enum.all?(modules, &is_binary/1)

        _ ->
          false
      end)

    if valid and Keyword.keyword?(options),
      do: :ok,
      else: {:error, "invalid dependency records or entrypoint options"}
  end

  defp manifest(app, entry, modules, dependencies, options) do
    records =
      modules
      |> Enum.sort_by(& &1.name)
      |> Enum.map(fn %{name: name, owner: owner, bytes: bytes} ->
        %{
          "name" => name,
          "owner" => owner,
          "path" => "modules/#{name}.beam",
          "size" => byte_size(bytes),
          "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
        }
      end)

    dep_records =
      dependencies
      |> Enum.sort_by(& &1.app)
      |> Enum.map(fn dep ->
        %{"app" => dep.app, "version" => dep.version, "modules" => Enum.sort(dep.modules)}
      end)

    {:ok,
     %{
       "format" => "midgard.beam",
       "format_version" => if(options[:gleam_version], do: 2, else: 1),
       "application" => app,
       "entrypoint" => %{
         "module" => entry,
         "function" => Keyword.get(options, :function, "__midgard_call__"),
         "arity" => 1,
         "protocol" => Keyword.get(options, :protocol, "midgard.bytes.v1")
       },
       "compiler" => compiler(options),
       "target" => %{
         "runtime" => "libbeam",
         "contract" => "provisional-isolate-v1",
         "execution" => "not_verified"
       },
       "dependencies" => dep_records,
       "modules" => records,
       "required_capabilities" => []
     }}
  end

  defp compiler(options) do
    otp = :erlang.system_info(:otp_release) |> to_string()

    case options[:gleam_version] do
      nil -> %{"otp_release" => otp, "elixir_version" => System.version()}
      version -> %{"otp_release" => otp, "gleam_version" => version}
    end
  end

  defp prepare_destination(output) do
    if File.dir?(Path.dirname(output)) do
      case File.lstat(output) do
        {:error, :enoent} -> :ok
        {:ok, %{type: :directory}} -> :ok
        {:ok, %{type: :symlink}} -> {:error, "output cannot be a symlink"}
        {:ok, _} -> {:error, "output is not a directory"}
        {:error, reason} -> {:error, "cannot inspect output: #{inspect(reason)}"}
      end
    else
      {:error, "output parent directory does not exist"}
    end
  end

  defp publish(stage, output) do
    if File.exists?(output) do
      backup = output <> ".old-#{System.unique_integer([:positive])}"

      with :ok <- File.rename(output, backup) do
        case File.rename(stage, output) do
          :ok ->
            File.rm_rf!(backup)
            :ok

          {:error, reason} ->
            File.rename(backup, output)
            {:error, "could not publish artifact: #{inspect(reason)}"}
        end
      end
    else
      File.rename(stage, output)
    end
  end
end
