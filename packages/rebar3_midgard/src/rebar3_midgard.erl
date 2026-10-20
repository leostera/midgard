-module(rebar3_midgard).
-export([init/1]).

init(State) ->
    {ok, State1} = rebar3_midgard_prv_pack:init(State),
    {ok, State2} = rebar3_midgard_prv_inspect:init(State1),
    rebar3_midgard_prv_deploy:init(State2).
