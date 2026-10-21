-module(swap).
-export([start/0]).
%% Boots :elixir from its real modules, then replaces every module found in
%% $SWAP_DIR with the shaken binary, so all later calls run shaken code.
start() ->
    {ok, _} = application:ensure_all_started(elixir),
    Dir = os:getenv("SWAP_DIR"),
    Files = filelib:wildcard(filename:join(Dir, "*.beam")),
    [begin
         M = list_to_atom(filename:basename(F, ".beam")),
         {ok, Bin} = file:read_file(F),
         code:purge(M),
         {module, M} = code:load_binary(M, F, Bin)
     end || F <- Files],
    io:format("swapped ~p modules~n", [length(Files)]),
    midgard_http:start().
