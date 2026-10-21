-module(erlang_worker_tests).
-include_lib("eunit/include/eunit.hrl").

http_routes_test() ->
    ?assertEqual(response(200, <<"Hello Joe!">>),
                 erlang_worker:handle(request(<<"GET">>, <<"/">>))),
    ?assertEqual(response(200, <<"hello, world!">>),
                 erlang_worker:handle(request(<<"GET">>, <<"/hello">>))),
    ?assertEqual(response(200, <<"hello, joe!">>),
                 erlang_worker:handle(request(<<"GET">>, <<"/hello/joe">>))),
    ?assertEqual(response(404, <<"Not found\n">>),
                 erlang_worker:handle(request(<<"POST">>, <<"/">>))),
    ?assertEqual(response(404, <<"Not found\n">>),
                 erlang_worker:handle(request(<<"GET">>, <<"/hello/joe/more">>))).

headers_and_body_test() ->
    Frame = <<1, 4:8, 1:16, 3:16, 1:8, 2:16, "POST", "/", "a=1",
              4:8, 2:16, "host", "me", "hi">>,
    ?assertEqual(response(404, <<"Not found\n">>), erlang_worker:handle(Frame)).

invalid_frame_test() ->
    ?assertEqual(response(400, <<"Bad request\n">>), erlang_worker:handle(<<0, 255>>)),
    Truncated = <<1, 3:8, 1:16, 0:16, 0:8, 5:16, "GET", "/", "hi">>,
    ?assertEqual(response(400, <<"Bad request\n">>), erlang_worker:handle(Truncated)).

request(Method, Path) ->
    <<1, (byte_size(Method)):8, (byte_size(Path)):16, 0:16, 0:8, 0:16,
      Method/binary, Path/binary>>.

response(Status, Body) -> <<2, Status:16, (byte_size(Body)):16, Body/binary>>.
