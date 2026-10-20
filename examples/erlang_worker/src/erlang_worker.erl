-module(erlang_worker).
-include_lib("midgard/include/midgard.hrl").
-export([handle/1]).

%% midgard.bytes.v1: the same bounded request/response envelope as Midgard.Worker.
%% The edge HTTP service frames requests; the Isolate handles only binary bytes.
handle(<<1, MethodSize:8, PathSize:16, QuerySize:16, HeaderCount:8,
         BodySize:16, Rest/binary>>)
  when MethodSize > 0, MethodSize =< 16, PathSize > 0, PathSize =< 2048,
       QuerySize =< 2048, HeaderCount =< 32, BodySize =< 32768 ->
    case Rest of
        <<Method:MethodSize/binary, Path:PathSize/binary, _Query:QuerySize/binary,
          HeaderAndBody/binary>> ->
            case skip_headers(HeaderCount, HeaderAndBody) of
                {ok, <<_Body:BodySize/binary>>} -> route(Method, Path);
                _ -> reply(400, <<"worker error\n">>)
            end;
        _ -> reply(400, <<"worker error\n">>)
    end;
handle(_) -> reply(400, <<"worker error\n">>).

skip_headers(0, Rest) -> {ok, Rest};
skip_headers(Count, <<NameSize:8, ValueSize:16, _Name:NameSize/binary,
                      _Value:ValueSize/binary, Rest/binary>>) when Count > 0 ->
    skip_headers(Count - 1, Rest);
skip_headers(_, _) -> error.

route(<<"GET">>, <<"/hello">>) -> reply(200, hello(<<"world">>));
route(<<"GET">>, <<"/hello/", Name/binary>>) ->
    case valid_name(Name) of
        true -> reply(200, hello(Name));
        false -> reply(404, <<"Not found\n">>)
    end;
route(_, _) -> reply(404, <<"Not found\n">>).

valid_name(<<>>) -> false;
valid_name(Name) -> no_slash(Name).

no_slash(<<>>) -> true;
no_slash(<<"/", _/binary>>) -> false;
no_slash(<<_, Rest/binary>>) -> no_slash(Rest).

hello(Name) -> <<"hello, ", Name/binary, "!">>.

reply(Status, Body) ->
    midgard:encode_response(#midgard_response{status = Status, body = Body}).
