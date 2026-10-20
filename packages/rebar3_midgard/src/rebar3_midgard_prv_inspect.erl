-module(rebar3_midgard_prv_inspect).
-behaviour(provider).
-export([init/1, do/1, format_error/1]).

init(State) ->
    Provider = providers:create([
        {name, inspect},
        {namespace, midgard},
        {module, ?MODULE},
        {bare, true},
        {deps, [{midgard, pack}]},
        {desc, "Verify the packaged Midgard artifact without executing it"},
        {example, "rebar3 midgard inspect"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

do(State) ->
    case artifact_path(State) of
        {ok, Artifact} ->
            case run_mix(["packer.inspect", Artifact]) of
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

artifact_path(State) ->
    Config = rebar_state:get(State, midgard, []),
    case project_app() of
        {ok, App} ->
            Output = proplists:get_value(output, Config, App ++ ".midgard"),
            case is_list(Output) of
                true -> {ok, Output};
                false -> {error, "output in {midgard, [...]} must be a string"}
            end;
        {error, Reason} -> {error, Reason}
    end.

project_app() ->
    case filelib:wildcard("src/*.app.src") of
        [Path] -> {ok, filename:basename(Path, ".app.src")};
        _ -> {error, "expected exactly one src/<application>.app.src"}
    end.

run_mix(Args) ->
    case os:find_executable("mix") of
        false -> {error, "Mix is required to inspect Midgard artifacts; install Elixir", []};
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
