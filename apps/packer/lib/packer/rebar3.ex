defmodule Packer.Rebar3 do
  @moduledoc """
  Trusted local adapter for one standalone rebar3 application. It invokes
  rebar3, reads compiled app metadata and BEAMs, and never loads guest code.
  """

  @app_pattern ~r/\A[a-z][a-z0-9_]*\z/
  @erlang_module_pattern ~r/\A[a-z][A-Za-z0-9_@]*\z/

  def pack(opts) do
    root = opts[:project]
    entry = opts[:entry]

    with :ok <- validate_options(root, entry, opts),
         root = Path.expand(root),
         {:ok, app} <- project_app(root),
         {:ok, executable} <- rebar3_executable(opts),
         :ok <- maybe_compile(root, executable, opts),
         {:ok, applications} <- collect_applications(root, app) do
      local = Enum.find(applications, &(&1.app == app))
      dependencies = Enum.reject(applications, &(&1.app == app))

      modules =
        for application <- applications, {name, bytes} <- application.beams do
          %{name: name, owner: application.app, bytes: bytes}
        end

      dep_records =
        for dep <- dependencies do
          %{app: dep.app, version: dep.version, modules: Enum.map(dep.beams, &elem(&1, 0))}
        end

      output = opts[:output] || Path.join(root, "#{app}.midgard")

      Packer.Artifact.build(output, local.app, to_string(entry), modules, dep_records,
        function: opts[:function],
        protocol: opts[:protocol]
      )
    end
  end

  defp validate_options(root, entry, opts) do
    if is_binary(root) and root != "" and is_binary(entry) and
         String.match?(entry, @erlang_module_pattern) and
         is_binary(opts[:function]) and opts[:function] != "" and
         is_binary(opts[:protocol]) and opts[:protocol] != "" and
         (is_nil(opts[:output]) or is_binary(opts[:output])) and
         (is_nil(opts[:skip_compile]) or is_boolean(opts[:skip_compile])) and
         not String.contains?(root, <<0>>) do
      :ok
    else
      {:error,
       "rebar3 projects require --project DIR --entry erlang_module --function NAME --protocol ID"}
    end
  end

  defp project_app(root) do
    app_files = Path.wildcard(Path.join(root, "src/*.app.src"))
    other_apps = Path.wildcard(Path.join(root, "{apps,lib}/*/src/*.app.src"))

    case {File.regular?(Path.join(root, "rebar.config")), app_files, other_apps} do
      {true, [file], []} ->
        app = Path.basename(file, ".app.src")

        if String.match?(app, @app_pattern),
          do: {:ok, app},
          else: {:error, "rebar3 application name is not supported: #{app}"}

      _ ->
        {:error,
         "expected one rebar.config and one src/<app>.app.src; rebar3 umbrellas are not supported"}
    end
  end

  defp rebar3_executable(opts) do
    if Keyword.get(opts, :skip_compile), do: {:ok, nil}, else: find_rebar3(opts[:rebar3])
  end

  defp maybe_compile(root, executable, opts) do
    if Keyword.get(opts, :skip_compile), do: :ok, else: compile(root, executable)
  end

  defp find_rebar3(nil) do
    case System.find_executable("rebar3") do
      nil -> {:error, "rebar3 is required; install it or pass --rebar3 PATH"}
      path -> {:ok, path}
    end
  end

  defp find_rebar3(path) when is_binary(path) do
    case System.find_executable(path) do
      nil -> {:error, "rebar3 executable not found: #{path}"}
      executable -> {:ok, executable}
    end
  end

  defp find_rebar3(_), do: {:error, "invalid rebar3 executable"}

  defp compile(root, executable) do
    case System.cmd(executable, ["compile"], cd: root, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, code} ->
        {:error, "rebar3 compile failed (exit #{code}): #{String.slice(output, 0, 8_000)}"}
    end
  rescue
    error -> {:error, "could not run rebar3: #{Exception.message(error)}"}
  end

  defp collect_applications(root, primary) do
    directories =
      Path.wildcard(Path.join(root, "_build/default/lib/*")) ++
        Path.wildcard(Path.join(root, "_build/default/checkouts/*"))

    plugin_apps = plugin_apps(root)

    directories =
      Enum.filter(directories, &application_directory?/1)
      |> Enum.reject(&(Path.basename(&1) in plugin_apps))

    with true <- Enum.any?(directories, &(Path.basename(&1) == primary)),
         {:ok, applications} <- read_applications(directories),
         names = Enum.map(applications, & &1.app),
         true <- length(names) == length(Enum.uniq(names)) and primary in names do
      {:ok, applications}
    else
      _ -> {:error, "compiled rebar3 application or dependency metadata is missing or ambiguous"}
    end
  end

  defp application_directory?(directory) do
    app = Path.basename(directory)

    String.match?(app, @app_pattern) and
      File.regular?(Path.join([directory, "ebin", "#{app}.app"]))
  end

  defp plugin_apps(root) do
    case :file.consult(String.to_charlist(Path.join(root, "rebar.config"))) do
      {:ok, config} ->
        [:plugins, :project_plugins]
        |> Enum.flat_map(fn key -> Keyword.get(config, key, []) end)
        |> Enum.map(fn
          {app, _source} -> Atom.to_string(app)
          app when is_atom(app) -> Atom.to_string(app)
        end)

      _ ->
        []
    end
  end

  defp read_applications(directories) do
    Enum.reduce_while(directories, {:ok, []}, fn directory, {:ok, acc} ->
      case read_application(directory) do
        {:ok, app} -> {:cont, {:ok, [app | acc]}}
        {:error, reason} -> {:halt, {:error, "#{Path.basename(directory)}: #{reason}"}}
      end
    end)
    |> case do
      {:ok, apps} -> {:ok, Enum.sort_by(apps, & &1.app)}
      error -> error
    end
  end

  defp read_application(directory) do
    app = Path.basename(directory)
    path = Path.join([directory, "ebin", "#{app}.app"])

    with true <- String.match?(app, @app_pattern) and File.regular?(path),
         {:ok, [{:application, name, props}]} <- :file.consult(String.to_charlist(path)),
         true <- is_atom(name) and Atom.to_string(name) == app and is_list(props),
         version when is_list(version) or is_binary(version) <- Keyword.get(props, :vsn),
         version = to_string(version),
         true <- byte_size(version) in 1..64 and String.valid?(version),
         declared when is_list(declared) <- Keyword.get(props, :modules),
         {:ok, beams} <- Packer.BeamFiles.collect(directory, Path.join(directory, "ebin")),
         true <-
           Enum.sort(Enum.map(declared, &Atom.to_string/1)) ==
             Enum.sort(Enum.map(beams, &elem(&1, 0))) do
      {:ok, %{app: app, version: version, beams: beams}}
    else
      false -> {:error, "compiled .app or module list does not match the BEAMs"}
      {:error, reason} -> {:error, "compiled .app or BEAMs unavailable: #{inspect(reason)}"}
      _ -> {:error, "invalid compiled .app metadata"}
    end
  rescue
    error -> {:error, "cannot read compiled app metadata: #{Exception.message(error)}"}
  end
end
