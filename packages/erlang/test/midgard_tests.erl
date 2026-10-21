-module(midgard_tests).
-include_lib("eunit/include/eunit.hrl").
-include("midgard.hrl").

decode_request_test() ->
    Frame = <<1, 4:8, 6:16, 3:16, 2:8, 2:16, "POST", "/hello", "a=1",
              4:8, 2:16, "host", "me", 1:8, 0:16, "x", "hi">>,
    ?assertEqual({ok, #midgard_request{method = <<"POST">>, path = <<"/hello">>,
                                       query_string = <<"a=1">>,
                                       headers = [{<<"host">>, <<"me">>}, {<<"x">>, <<>>}],
                                       body = <<"hi">>}},
                 midgard:decode_request(Frame)).

decode_rejects_malformed_frames_test() ->
    ?assertEqual(error, midgard:decode_request(<<>>)),
    ?assertEqual(error, midgard:decode_request(<<2, 3:8, 1:16, 0:16, 0:8, 0:16, "GET/">>)),
    ?assertEqual(error, midgard:decode_request(<<1, 3:8, 1:16, 0:16, 0:8, 1:16, "GET/">>)),
    ?assertEqual(error, midgard:decode_request(<<1, 3:8, 1:16, 0:16, 0:8, 0:16, "GET/x">>)).

serve_test() ->
    Handler = fun(#midgard_request{path = Path}) -> #midgard_response{status = 200, body = Path} end,
    ?assertEqual(<<2, 200:16, 1:16, "/">>,
                 midgard:serve(<<1, 3:8, 1:16, 0:16, 0:8, 0:16, "GET/">>, Handler)),
    ?assertEqual(<<2, 400:16, 12:16, "Bad request\n">>, midgard:serve(<<>>, Handler)).

encode_response_test() ->
    ?assertEqual(<<2, 200:16, 2:16, "ok">>,
                 midgard:encode_response(#midgard_response{status = 200, body = <<"ok">>})).
