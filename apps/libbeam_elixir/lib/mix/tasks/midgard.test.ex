defmodule Mix.Tasks.Midgard.Test do
  use Mix.Task

  @moduledoc """
  Runs the prototype BEAM test convention in fresh libbeam Isolates.

  Discovers `*_test.exs` files using `Midgard.Test` and `*_test.erl` files
  exporting `run/1` beneath the selected path. See the libbeam_elixir README
  for supported options and current compatibility limitations.
  """

  @shortdoc "Run deterministic BEAM tests inside libbeam Isolates"
  @default_epoch_ms 946_684_800_000
  @max_epoch_ms div(18_446_744_073_709_551_615, 1_000_000)

  @impl true
  def run(arguments) do
    Mix.Task.run("app.config")

    {options, positional, invalid} =
      OptionParser.parse(arguments,
        strict: [path: :string, epoch_ms: :integer, auto_advance: :boolean],
        aliases: [p: :path, e: :epoch_ms]
      )

    path = Keyword.get(options, :path, default_test_path())
    epoch_ms = Keyword.get(options, :epoch_ms, @default_epoch_ms)
    auto_advance = Keyword.get(options, :auto_advance, true)

    if positional != [] or invalid != [] or not valid_epoch?(epoch_ms) do
      Mix.raise(
        "Usage: mix midgard.test [--path test/libbeam] [--epoch-ms INTEGER] [--no-auto-advance]"
      )
    end

    test_files =
      (Path.wildcard(Path.join(path, "**/*_test.exs")) ++
         Path.wildcard(Path.join(path, "**/*_test.erl")))
      |> Enum.sort()

    if test_files == [] do
      Mix.raise("No libbeam tests found under #{path}; add *_test.exs or *_test.erl files")
    end

    {compiled, beams} = compile_tests!(test_files)
    cases = collect_cases!(compiled)

    if cases == [] do
      Mix.raise(
        "No libbeam cases found under #{path}; Elixir modules use Midgard.Test and Erlang modules export run/1"
      )
    end

    Mix.shell().info(
      "Running #{length(cases)} libbeam tests (epoch=#{epoch_ms}, auto_advance=#{auto_advance})"
    )

    failures =
      Enum.flat_map(cases, fn {module, name, input} ->
        case run_case(module, input, beams, epoch_ms, auto_advance) do
          :ok ->
            Mix.shell().info("  PASS #{inspect(module)}: #{name}")
            []

          {:error, reason} ->
            Mix.shell().error("  FAIL #{inspect(module)}: #{name}: #{reason}")
            [{module, name, reason}]
        end
      end)

    if failures != [] do
      Mix.raise("#{length(failures)} of #{length(cases)} libbeam tests failed")
    end

    Mix.shell().info("All #{length(cases)} libbeam tests passed")
  end

  defp default_test_path do
    cond do
      File.dir?("test/libbeam") -> "test/libbeam"
      File.dir?("apps/libbeam_elixir/test/libbeam") -> "apps/libbeam_elixir/test/libbeam"
      true -> "test/libbeam"
    end
  end

  defp valid_epoch?(epoch_ms),
    do: is_integer(epoch_ms) and epoch_ms >= 0 and epoch_ms <= @max_epoch_ms

  defp compile_tests!(files) do
    compiled =
      Enum.flat_map(files, fn
        file when is_binary(file) ->
          if String.ends_with?(file, ".erl") do
            case :compile.file(String.to_charlist(file), [:binary, :deterministic]) do
              {:ok, module, beam} ->
                [{module, beam, file, :erlang}]

              {:error, errors, _warnings} ->
                Mix.raise("Could not compile #{file}: #{inspect(errors)}")
            end
          else
            Code.compile_file(file)
            |> Enum.map(fn {module, beam} -> {module, beam, file, :elixir} end)
          end
      end)

    beams = Enum.map(compiled, fn {_module, beam, _file, _language} -> beam end)
    {compiled, beams}
  rescue
    error -> Mix.raise("Could not compile libbeam tests: #{Exception.message(error)}")
  end

  defp collect_cases!(compiled) do
    Enum.flat_map(compiled, fn
      {module, _beam, _file, :elixir} ->
        if function_exported?(module, :__midgard_test_cases__, 0) do
          Enum.map(module.__midgard_test_cases__(), fn {index, name} ->
            {module, name, <<index::32>>}
          end)
        else
          []
        end

      _ ->
        []
    end) ++
      Enum.flat_map(compiled, fn
        {module, beam, file, :erlang} ->
          with {:ok, {^module, chunks}} <- :beam_lib.chunks(beam, [:exports]),
               true <- {:run, 1} in chunks[:exports] do
            [{module, Path.basename(file), <<>>}]
          else
            _ -> []
          end

        _ ->
          []
      end)
  end

  defp run_case(module, input, beams, epoch_ms, auto_advance) do
    with {:ok, engine} <- Libbeam.Engine.start() do
      case Libbeam.Engine.create_isolate(engine,
             virtual_time: [epoch_ms: epoch_ms, auto_advance: auto_advance]
           ) do
        {:ok, isolate} ->
          run_in_isolate(engine, isolate, module, input, beams)

        {:error, error} ->
          _ = Libbeam.Engine.shutdown(engine)
          {:error, Exception.message(error)}
      end
    else
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp run_in_isolate(engine, isolate, module, input, beams) do
    try do
      with :ok <- Libbeam.Isolate.load_modules(isolate, beams),
           {:ok, <<"ok">>} <-
             Libbeam.Isolate.call(isolate, Atom.to_string(module), "run", input) do
        :ok
      else
        {:ok, other} -> {:error, "test returned #{inspect(other)}, expected <<\"ok\">>"}
        {:error, error} -> {:error, Exception.message(error)}
      end
    after
      _ = Libbeam.Isolate.stop(isolate)
      _ = Libbeam.Engine.shutdown(engine)
    end
  end
end
