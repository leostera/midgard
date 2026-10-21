-module(erlang_worker).
-include_lib("midgard/include/midgard.hrl").
-export([handle/1, handle_request/1]).

%% Binary entrypoint: the edge frames each HTTP request as midgard.bytes.v1.
handle(Input) -> midgard:serve(Input, fun handle_request/1).

handle_request(#midgard_request{method = <<"GET">>, path = <<"/">>}) ->
    #midgard_response{status = 200, body = <<"Hello Joe!">>};
handle_request(#midgard_request{method = <<"GET">>, path = <<"/hello">>}) ->
    hello(<<"world">>);
handle_request(#midgard_request{method = <<"GET">>, path = <<"/hello/", Name/binary>>}) ->
    case valid_name(Name) of
        true -> hello(Name);
        false -> not_found()
    end;
handle_request(_Request) ->
    not_found().

hello(Name) ->
    #midgard_response{status = 200, body = <<"hello, ", Name/binary, "!">>}.

not_found() ->
    #midgard_response{status = 404, body = <<"Not found\n">>}.

valid_name(<<>>) -> false;
valid_name(Name) -> no_slash(Name).

no_slash(<<>>) -> true;
no_slash(<<"/", _/binary>>) -> false;
no_slash(<<_, Rest/binary>>) -> no_slash(Rest).
