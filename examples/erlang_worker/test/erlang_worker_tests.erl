-module(erlang_worker_tests).
-include_lib("eunit/include/eunit.hrl").

http_routes_test() ->
    ?assertEqual(response(200, <<"Hello from Erlang!\n">>),
                 erlang_worker:handle(request(<<"GET">>, <<"/hello">>))),
    ?assertEqual(response(200, <<"Hello from joe\n">>),
                 erlang_worker:handle(request(<<"GET">>, <<"/hello/joe">>))),
    ?assertEqual(response(404, <<"Not found\n">>),
                 erlang_worker:handle(request(<<"GET">>, <<"/">>))),
    ?assertEqual(response(404, <<"Not found\n">>),
                 erlang_worker:handle(request(<<"POST">>, <<"/hello/joe">>))),
    ?assertEqual(response(404, <<"Not found\n">>),
                 erlang_worker:handle(request(<<"GET">>, <<"/hello/joe/more">>))).

invalid_frame_test() ->
    ?assertEqual(response(400, <<"worker error\n">>), erlang_worker:handle(<<0, 255>>)).

request(Method, Path) ->
    <<1, (byte_size(Method)):8, (byte_size(Path)):16, 0:16, 0:8, 0:16,
      Method/binary, Path/binary>>.

response(Status, Body) -> <<2, Status:16, (byte_size(Body)):16, Body/binary>>.
