defmodule Midgard.CLI.Generator do
  @moduledoc "Scaffolds trusted-local worker projects using Hex, pinned Git, or checkout-local dependencies."

  @default_root Path.expand("../../../../..", __DIR__)
  @repository "https://github.com/leostera/midgard.git"
  @archive_revision System.get_env("MIDGARD_SOURCE_COMMIT") ||
                      (case System.cmd("git", ["rev-parse", "HEAD"],
                              cd: __DIR__,
                              stderr_to_stdout: true
                            ) do
                         {hash, 0} -> String.trim(hash)
                         _ -> nil
                       end)

  def default_root, do: @default_root
  def archive_revision, do: @archive_revision

  def generate_from_archive(name, destination) do
    case @archive_revision do
      <<_::binary-size(40)>> = revision -> generate_from_git(name, destination, revision)
      _ -> generate_from_hex(name, destination)
    end
  end

  def generate_from_hex(name, destination)
      when is_binary(name) and is_binary(destination) do
    destination = Path.expand(destination)

    with :ok <- validate_name(name),
         :ok <- validate_destination(destination) do
      write_project(
        name,
        destination,
        Macro.camelize(name),
        hex_dependencies(),
        "Hex packages `midgard` and `midgard_packer`"
      )
    end
  rescue
    error -> {:error, "could not create project: #{Exception.message(error)}"}
  end

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
    {:packer, path: #{inspect(Path.join(root, "apps/packer"))}, only: [:dev, :test], runtime: false}
    """
  end

  defp hex_dependencies do
    """
    {:midgard, "~> 0.3"},
    {:packer, hex: "midgard_packer", version: "~> 0.3", only: [:dev, :test], runtime: false}
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
    if Enum.all?(~w(midgard packer), fn app ->
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
        def handle_request(%Midgard.Request{method: "GET", path: "/"}) do
          {200, "Hello Joe!"}
        end

        def handle_request(%Midgard.Request{method: "GET", path: "/hello/" <> name})
            when name != "",
          do: {200, __MODULE__.Greeting.hello(name)}

        def handle_request(%Midgard.Request{method: "GET", path: "/hello"}),
          do: {200, __MODULE__.Greeting.hello("world")}

        def handle_request(_request), do: {404, "Not found\n"}
      end
      """
      |> String.replace("__MODULE__", module)

    greeting =
      ~S"""
      defmodule __MODULE__.Greeting do
        def hello(name), do: "hello, " <> name <> "!"
      end
      """
      |> String.replace("__MODULE__", module)

    test =
      ~S"""
      defmodule __MODULE__Test do
        use ExUnit.Case, async: true

        test "greets the path name through the provisional binary entrypoint" do
          request = Midgard.Request.new("GET", "/hello/ada")
          assert __MODULE__.handle_request(request) == {200, "hello, ada!"}
          assert __MODULE__.handle_request(Midgard.Request.new("GET", "/hello")) ==
                   {200, "hello, world!"}
          assert __MODULE__.handle_request(Midgard.Request.new("GET", "/")) ==
                   {200, "Hello Joe!"}
          assert {:ok, bytes} = Midgard.Protocol.request(request)
          assert {:ok, {200, "hello, ada!"}} =
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
          elixir: "~> 1.21.0-dev",
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

    Generated by `mix midgard.new`. Midgard is a **tech demo**: Elixir workers
    require OTP 29 and the latest Elixir (`main`) at source revision
    `13299af2b91a6aff7e430f25849f586c02b3231f`, matching the live runtime.
    Packer rejects other Elixir revisions before upload. Dependencies use
    #{origin}. A locally installed Mix archive provides `mix midgard.deploy`.

    ```sh
    git clone https://github.com/elixir-lang/elixir.git /tmp/midgard-elixir
    git -C /tmp/midgard-elixir checkout 13299af2b91a6aff7e430f25849f586c02b3231f
    make -C /tmp/midgard-elixir compile install PREFIX=/tmp/midgard-toolchain
    export PATH="/tmp/midgard-toolchain/bin:$PATH"
    mix deps.get
    mix test
    mix midgard.deploy
    ```

    The deploy prints a new, immutable public Worker URL. `GET /` responds
    with `Hello Joe!`; `GET /hello/joe` responds with `hello, joe!`.
    Deployments are public demos: don't include secrets or private code.

    `mix packer.pack` and `mix packer.inspect #{name}.midgard` build and inspect
    the artifact without uploading it. Pass `--endpoint http://127.0.0.1:4000`
    to `mix midgard.deploy` to target a local platform instead.
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
