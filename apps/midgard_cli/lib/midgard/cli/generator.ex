defmodule Midgard.CLI.Generator do
  @moduledoc "Scaffolds trusted-local worker projects with pinned Git or checkout-local dependencies."

  @default_root Path.expand("../../../../..", __DIR__)
  @repository "https://github.com/leostera/midgard.git"
  @archive_revision (case System.cmd("git", ["rev-parse", "HEAD"],
                            cd: __DIR__,
                            stderr_to_stdout: true
                          ) do
                       {hash, 0} -> String.trim(hash)
                       _ -> nil
                     end)

  def default_root, do: @default_root
  def archive_revision, do: @archive_revision

  def generate(name, destination, root)
      when is_binary(name) and is_binary(destination) and is_binary(root) do
    root = Path.expand(root)
    destination = Path.expand(destination)

    with :ok <- validate_name(name),
         :ok <- validate_checkout(root),
         :ok <- validate_destination(destination) do
      module = Macro.camelize(name)
      dependencies = local_dependencies(root)
      write_project(name, destination, module, dependencies, "local paths into #{root}")
    end
  rescue
    error -> {:error, "could not create project: #{Exception.message(error)}"}
  end

  def generate(_, _, _), do: {:error, "expected a project name, destination, and checkout path"}

  def generate_from_git(name, destination, revision)
      when is_binary(name) and is_binary(destination) and is_binary(revision) do
    destination = Path.expand(destination)

    with :ok <- validate_name(name),
         :ok <- validate_revision(revision),
         :ok <- validate_destination(destination) do
      write_project(
        name,
        destination,
        Macro.camelize(name),
        git_dependencies(revision),
        "Git revision #{revision} of #{@repository}"
      )
    end
  rescue
    error -> {:error, "could not create project: #{Exception.message(error)}"}
  end

  def generate_from_git(_, _, _),
    do: {:error, "archive has no pinned Git revision; use --midgard-root PATH"}

  defp write_project(name, destination, module, dependencies, origin) do
    files = template_files(name, module, dependencies, origin)
    File.mkdir_p!(destination)

    Enum.each(files, fn {path, content} ->
      file = Path.join(destination, path)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, format_source(path, content))
    end)

    {:ok, destination}
  end

  defp validate_revision(<<_::binary-size(40)>> = revision) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, revision),
      do: :ok,
      else: {:error, "invalid Git revision"}
  end

  defp validate_revision(_),
    do: {:error, "archive has no pinned Git revision; use --midgard-root PATH"}

  defp local_dependencies(root) do
    """
    {:midgard, path: #{inspect(Path.join(root, "apps/midgard"))}},
    {:packer, path: #{inspect(Path.join(root, "apps/packer"))}, only: [:dev, :test], runtime: false},
    {:midgard_cli, path: #{inspect(Path.join(root, "apps/midgard_cli"))}, only: [:dev, :test], runtime: false}
    """
  end

  defp git_dependencies(revision) do
    """
    {:midgard, git: #{@repository |> inspect()}, ref: #{inspect(revision)}, subdir: "apps/midgard"},
    {:packer, git: #{@repository |> inspect()}, ref: #{inspect(revision)}, subdir: "apps/packer", only: [:dev, :test], runtime: false}
    """
  end

  defp format_source(path, content) do
    if Path.extname(path) in [".ex", ".exs"] do
      content |> Code.format_string!() |> IO.iodata_to_binary() |> Kernel.<>("\n")
    else
      content
    end
  end

  defp validate_name(name) do
    if String.match?(name, ~r/\A[a-z][a-z0-9_]*\z/),
      do: :ok,
      else: {:error, "name must be snake_case (lowercase letters, digits, underscores)"}
  end

  defp validate_checkout(root) do
    if Enum.all?(~w(midgard packer midgard_cli), fn app ->
         File.regular?(Path.join([root, "apps", app, "mix.exs"]))
       end),
       do: :ok,
       else: {:error, "--midgard-root must point to this repository's checkout"}
  end

  defp validate_destination(destination) do
    if File.exists?(destination),
      do: {:error, "destination already exists: #{destination}"},
      else: :ok
  end

  defp template_files(name, module, dependencies, origin) do
    worker =
      ~S"""
      defmodule __MODULE__ do
        use Midgard.Worker

        @impl true
        def handle_request(%Midgard.Request{method: "GET", path: path})
            when path in ["/", "/hello"],
          do: {200, __MODULE__.Greeting.hello()}

        def handle_request(_request), do: {404, "Not found\n"}
      end
      """
      |> String.replace("__MODULE__", module)

    greeting =
      ~S"""
      defmodule __MODULE__.Greeting do
        def hello, do: "Hello from __MODULE__!\n"
      end
      """
      |> String.replace("__MODULE__", module)

    test =
      ~S"""
      defmodule __MODULE__Test do
        use ExUnit.Case, async: true

        test "handles the hello route through the provisional binary entrypoint" do
          request = Midgard.Request.new("GET", "/hello")
          assert __MODULE__.handle_request(request) == {200, "Hello from __MODULE__!\n"}
          assert __MODULE__.handle_request(Midgard.Request.new("GET", "/")) ==
                   {200, "Hello from __MODULE__!\n"}
          assert {:ok, bytes} = Midgard.Protocol.request(request)
          assert {:ok, {200, "Hello from __MODULE__!\n"}} =
                   bytes |> __MODULE__.__midgard_call__() |> Midgard.Protocol.decode_response()
        end

        test "responds to unknown routes" do
          assert __MODULE__.handle_request(Midgard.Request.new("GET", "/missing")) ==
                   {404, "Not found\n"}
        end
      end
      """
      |> String.replace("__MODULE__", module)

    mix = """
    defmodule #{module}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{name},
          version: "0.1.0",
          elixir: "~> 1.19",
          packer: [entry: #{module}],
          deps: [
            #{dependencies}
          ]
        ]
      end
    end
    """

    readme = """
    # #{module}

    Generated by `mix midgard.new`. Dependencies use #{origin}.
    A locally installed Mix archive provides `mix midgard.deploy`.

    ```sh
    mix deps.get
    mix test
    mix packer.pack     # creates #{name}.midgard/
    mix packer.inspect #{name}.midgard
    mix midgard.build   # reads midgard.config.exs; also creates #{name}.midgard/
    mix midgard.deploy --endpoint http://127.0.0.1:4000
    ```

    A successful deployment response means the exact shipment was verified and
    admitted by the local libbeam host. Remote deployment remains disabled until
    ownership, durable recovery, and abuse controls are implemented.
    """

    [
      {"mix.exs", mix},
      {"midgard.config.exs", "[entry: #{module}, target: :libbeam]\n"},
      {".formatter.exs",
       "[inputs: [\"mix.exs\", \"midgard.config.exs\", \"{lib,test}/**/*.{ex,exs}\"]]\n"},
      {".gitignore", "/_build/\n/deps/\n/#{name}.midgard/\n"},
      {"lib/#{name}.ex", worker},
      {"lib/#{name}/greeting.ex", greeting},
      {"test/test_helper.exs", "ExUnit.start()\n"},
      {"test/#{name}_test.exs", test},
      {"README.md", readme}
    ]
  end
end
