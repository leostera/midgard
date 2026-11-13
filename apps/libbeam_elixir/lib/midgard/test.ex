defmodule Midgard.Test do
  @moduledoc """
  Defines small BEAM tests that run inside isolated libbeam worlds.

  Test bodies are compiled normally by Elixir but execute only in libbeam. Keep
  them self-contained and use `assert/1` for conditions that should fail the case.
  """

  defmacro __using__(_options) do
    quote do
      Module.register_attribute(__MODULE__, :midgard_test_cases, persist: false)
      Module.register_attribute(__MODULE__, :midgard_test_counter, persist: false)
      import Midgard.Test, only: [test: 2, assert: 1]
      @before_compile Midgard.Test
    end
  end

  defmacro test(name, do: body) when is_binary(name) do
    module = __CALLER__.module
    index = Module.get_attribute(module, :midgard_test_counter) || 0
    Module.put_attribute(module, :midgard_test_counter, index + 1)
    function = String.to_atom("__midgard_test_case_#{index}")
    cases = Module.get_attribute(module, :midgard_test_cases) || []
    Module.put_attribute(module, :midgard_test_cases, [{index, name, function} | cases])

    quote do
      defp unquote(function)(), do: unquote(body)
    end
  end

  defmacro assert(expression) do
    quote do
      case unquote(expression) do
        true -> :ok
        other -> :erlang.error({:midgard_assertion_failed, other})
      end
    end
  end

  defmacro __before_compile__(environment) do
    cases = Module.get_attribute(environment.module, :midgard_test_cases) || []
    cases = Enum.sort_by(cases, fn {index, _, _} -> index end)

    metadata = Enum.map(cases, fn {index, name, _function} -> {index, name} end)

    run_clauses =
      Enum.map(cases, fn {index, _name, function} ->
        quote do
          def run(<<unquote(index)::32>>) do
            unquote(function)()
            <<"ok">>
          end
        end
      end)

    quote do
      def __midgard_test_cases__, do: unquote(Macro.escape(metadata))
      unquote_splicing(run_clauses)
      def run(_), do: :erlang.error(:unknown_midgard_test_case)
    end
  end
end
