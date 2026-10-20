defmodule Packer.Gleam do
  @moduledoc """
  Packages the production Erlang shipment of a trusted, single-package Gleam
  project. The shipment's .app module lists, not its incidental BEAM files,
  define what belongs to the artifact.
  """

  @app_pattern ~r/\A[a-z][a-z0-9_]*\z/

  def pack(opts) do
    root = opts[:project]

    with :ok <- validate_options(opts),
         root = Path.expand(root),
         {:ok, executable} <- executable(opts[:gleam_bin]),
         {:ok, project} <- project_info(root, executable),
         {:ok, lock} <- File.read(Path.join(root, "manifest.toml")),
         :ok <- reject_native_sources([root | project.local_dependencies]),
         {:ok, version} <- gleam_version(executable),
         :ok <- export(root, executable),
         :ok <- lock_unchanged(root, lock),
         :ok <- reject_native_sources([root | project.local_dependencies]),
         {:ok, apps} <- shipment(root, project.name) do
      modules =
        for app <- apps,
            {name, bytes} <- app.beams,
            do: %{name: name, owner: app.app, bytes: bytes}

      dependencies =
        for app <- apps,
            app.app != project.name,
            do: %{app: app.app, version: app.version, modules: Enum.map(app.beams, &elem(&1, 0))}

      output = opts[:output] || Path.join(root, "#{project.name}.midgard")

      Packer.Artifact.build(output, project.name, opts[:entry], modules, dependencies,
        function: opts[:function],
        protocol: opts[:protocol],
        gleam_version: version
      )
    end
  end

  defp validate_options(opts) do
    if is_binary(opts[:project]) and opts[:project] != "" and
         is_binary(opts[:entry]) and String.match?(opts[:entry], ~r/\A[a-z][A-Za-z0-9_@]*\z/) and
         is_binary(opts[:function]) and opts[:function] != "" and
         is_binary(opts[:protocol]) and opts[:protocol] != "" and
         (is_nil(opts[:output]) or is_binary(opts[:output])) and
         not Enum.any?(
           [opts[:project], opts[:entry], opts[:function], opts[:protocol], opts[:output] || ""],
           &String.contains?(&1, <<0>>)
         ) do
      :ok
    else
      {:error,
       "Gleam projects require --project DIR --gleam --entry module --function NAME --protocol ID"}
    end
  end

  defp executable(nil), do: executable("gleam")

  defp executable(path) when is_binary(path) do
    case System.find_executable(path) do
      nil -> {:error, "gleam executable not found: #{path}"}
      executable -> {:ok, executable}
    end
  end

  defp executable(_), do: {:error, "invalid Gleam executable"}

  defp project_info(root, executable) do
    with true <- File.regular?(Path.join(root, "gleam.toml")),
         true <- File.regular?(Path.join(root, "manifest.toml")),
         {:ok, output} <- run(executable, ["export", "package-information"], root),
         {:ok,
          %{
            "gleam.toml" => %{
              "name" => name,
              "target" => "erlang",
              "dependencies" => dependencies
            }
          }} <- Packer.JSON.decode(output),
         true <- is_binary(name) and String.match?(name, @app_pattern),
         {:ok, local_dependencies} <- local_dependency_paths(root, dependencies) do
      {:ok, %{name: name, local_dependencies: local_dependencies}}
    else
      {:error, reason} ->
        {:error, "invalid Gleam project: #{reason}"}

      _ ->
        {:error,
         "expected Erlang-target gleam.toml, locked manifest.toml and one valid package name"}
    end
  end

  defp lock_unchanged(root, original) do
    if File.read(Path.join(root, "manifest.toml")) == {:ok, original},
      do: :ok,
      else:
        {:error, "Gleam changed manifest.toml during export; commit the resolved lock and retry"}
  end

  defp gleam_version(executable) do
    with {:ok, output} <- run(executable, ["--version"], nil),
         [version] <-
           Regex.run(~r/\Agleam ([0-9][A-Za-z0-9.\-+]*)\s*\z/, output, capture: :all_but_first) do
      {:ok, version}
    else
      _ -> {:error, "could not identify Gleam compiler version"}
    end
  end

  defp export(root, executable) do
    case run(executable, ["export", "erlang-shipment"], root) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp run(executable, args, nil), do: run(executable, args, File.cwd!())

  defp run(executable, args, root) do
    case System.cmd(executable, args, cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, code} ->
        {:error,
         "gleam #{Enum.join(args, " ")} failed (exit #{code}): #{String.slice(output, 0, 8_000)}"}
    end
  rescue
    error -> {:error, "could not run gleam: #{Exception.message(error)}"}
  end

  defp local_dependency_paths(root, dependencies) when is_map(dependencies) do
    Enum.reduce_while(dependencies, {:ok, []}, fn
      {_name, %{"path" => path}}, {:ok, paths} when is_binary(path) ->
        {:cont, {:ok, [Path.expand(path, root) | paths]}}

      {_name, _configuration}, result ->
        {:cont, result}
    end)
  end

  defp local_dependency_paths(_root, _dependencies), do: {:error, "invalid Gleam dependencies"}

  defp reject_native_sources(roots) do
    native_dirs =
      Enum.flat_map(roots, &Path.wildcard(Path.join(&1, "**/{c_src,native,priv}")))

    native_files =
      Enum.flat_map(roots, &Path.wildcard(Path.join(&1, "**/*.{so,dylib,dll,a}")))

    if native_dirs != [] or native_files != [] do
      {:error, "native code or unpackaged priv resources in Gleam project or dependency"}
    else
      :ok
    end
  end

  defp shipment(root, project) do
    dir = Path.join(root, "build/erlang-shipment")
    app_files = Path.wildcard(Path.join(dir, "*/ebin/*.app")) |> Enum.sort()

    with true <-
           File.dir?(dir) and app_files != [] and
             File.regular?(Path.join(dir, "#{project}/ebin/#{project}.app")),
         app_dirs <- Path.wildcard(Path.join(dir, "*")) |> Enum.filter(&File.dir?/1),
         true <-
           length(app_dirs) == length(app_files) and
             Enum.all?(app_dirs, fn path ->
               app = Path.basename(path)
               File.regular?(Path.join(path, "ebin/#{app}.app"))
             end),
         {:ok, apps} <- read_apps(app_files),
         names = Enum.map(apps, & &1.app),
         true <- length(names) == length(Enum.uniq(names)) and project in names do
      {:ok, apps}
    else
      {:error, _} = error -> error
      _ -> {:error, "Gleam Erlang shipment is missing or has duplicate application metadata"}
    end
  end

  defp read_apps(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, apps} ->
      case read_app(file) do
        {:ok, app} -> {:cont, {:ok, [app | apps]}}
        {:error, reason} -> {:halt, {:error, "#{file}: #{reason}"}}
      end
    end)
  end

  defp read_app(file) do
    app = Path.basename(file, ".app")
    ebin = Path.dirname(file)

    with true <- String.match?(app, @app_pattern),
         {:ok, [{:application, name, properties}]} <- :file.consult(String.to_charlist(file)),
         true <- is_atom(name) and Atom.to_string(name) == app and is_list(properties),
         version when is_list(version) or is_binary(version) <- Keyword.get(properties, :vsn),
         version = to_string(version),
         true <- byte_size(version) in 1..64 and String.valid?(version),
         declared when is_list(declared) and declared != [] <- Keyword.get(properties, :modules),
         true <- Enum.all?(declared, &is_atom/1),
         names = Enum.map(declared, &Atom.to_string/1),
         true <- length(names) == length(Enum.uniq(names)),
         :ok <- check_files(ebin, app, names),
         {:ok, beams} <- read_beams(ebin, names) do
      {:ok, %{app: app, version: version, beams: beams}}
    else
      {:error, _} = error -> error
      _ -> {:error, "invalid shipment .app metadata or BEAM module list"}
    end
  end

  defp check_files(ebin, app, declared) do
    actual = Path.wildcard(Path.join(ebin, "*.beam")) |> Enum.map(&Path.basename(&1, ".beam"))
    # Gleam adds an undeclared CLI launcher; it imports process and host IO.
    extra = actual -- declared

    if declared -- actual == [] and
         extra -- ["#{app}@@main"] == [] and
         not File.exists?(Path.join(Path.dirname(ebin), "priv")) do
      :ok
    else
      {:error, "undeclared BEAM, missing declared BEAM or unpackaged priv resources"}
    end
  end

  defp read_beams(ebin, names) do
    Enum.reduce_while(Enum.sort(names), {:ok, []}, fn name, {:ok, beams} ->
      path = Path.join(ebin, "#{name}.beam")

      case File.read(path) do
        {:ok, bytes} -> {:cont, {:ok, [{name, bytes} | beams]}}
        {:error, reason} -> {:halt, {:error, "cannot read #{path}: #{inspect(reason)}"}}
      end
    end)
  end
end
