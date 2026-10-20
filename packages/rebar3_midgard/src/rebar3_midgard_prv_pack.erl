-module(rebar3_midgard_prv_pack).
-behaviour(provider).
-export([init/1, do/1, format_error/1]).

init(State) ->
    Provider = providers:create([
        {name, pack},
        {namespace, midgard},
        {module, ?MODULE},
        {bare, true},
        {deps, [{default, compile}]},
        {desc, "Compile and package this Rebar3 application for Midgard"},
        {example, "rebar3 midgard pack"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

do(State) ->
    case configuration(State) of
        {ok, Args} ->
            case run_mix(Args) of
                {ok, Output} ->
                    rebar_api:console("~ts", [Output]),
                    {ok, State};
                {error, Reason, Output} ->
                    {error, {?MODULE, {Reason, Output}}}
            end;
        {error, Reason} ->
            {error, {?MODULE, {configuration, Reason}}}
    end.

format_error({configuration, Reason}) ->
    ["invalid Rebar3 Midgard configuration: ", Reason];
format_error({Reason, Output}) ->
    [Reason, ":\n", Output].

configuration(State) ->
    Config = rebar_state:get(State, midgard, []),
    case {project_app(), proplists:get_value(entry, Config)} of
        {{ok, App}, Entry} when is_atom(Entry); is_list(Entry) ->
            Function = proplists:get_value(function, Config, handle),
            Protocol = proplists:get_value(protocol, Config, "midgard.bytes.v1"),
            Output = proplists:get_value(output, Config, App ++ ".midgard"),
            case {as_string(Function), as_string(Protocol), as_string(Output)} of
                {{ok, FunctionName}, {ok, ProtocolName}, {ok, OutputPath}} ->
                    {ok, ["packer.pack", "--project", ".", "--entry", as_string_value(Entry),
                          "--function", FunctionName, "--protocol", ProtocolName,
                          "--skip-compile", "--output", OutputPath]};
                _ -> {error, "function, protocol, and output must be strings or atoms"}
            end;
        {{error, Reason}, _} -> {error, Reason};
        {_, _} -> {error, "set {midgard, [{entry, module_name}]} in rebar.config"}
    end.

project_app() ->
    case filelib:wildcard("src/*.app.src") of
        [Path] -> {ok, filename:basename(Path, ".app.src")};
        _ -> {error, "expected exactly one src/<application>.app.src"}
    end.

as_string(Value) when is_atom(Value) -> {ok, atom_to_list(Value)};
as_string(Value) when is_list(Value) -> {ok, Value};
as_string(_) -> error.

as_string_value(Value) when is_atom(Value) -> atom_to_list(Value);
as_string_value(Value) -> Value.

run_mix(Args) ->
    case os:find_executable("mix") of
        false -> {error, "Mix is required to run Packer; install Elixir and the Midgard Packer archive", []};
        Executable -> collect(open_port({spawn_executable, Executable},
                                        [binary, use_stdio, stderr_to_stdout, exit_status,
                                         {args, Args}]), [])
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Acc]);
        {Port, {exit_status, 0}} -> {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, Status}} ->
            {error, lists:flatten(io_lib:format("mix exited with status ~B", [Status])),
             iolist_to_binary(lists:reverse(Acc))}
    end.
