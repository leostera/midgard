import midgard

/// Binary entrypoint: the edge frames each HTTP request as midgard.bytes.v1.
pub fn handle(input: BitArray) -> BitArray {
  midgard.serve(input, handle_request)
}

pub fn handle_request(request: midgard.Request) -> midgard.Response {
  case request.method, request.path {
    <<"GET":utf8>>, <<"/":utf8>> -> midgard.Response(200, <<"Hello Joe!":utf8>>)
    <<"GET":utf8>>, <<"/hello":utf8>> -> hello(<<"world":utf8>>)
    <<"GET":utf8>>, <<"/hello/":utf8, name:bits>> ->
      case valid_name(name) {
        True -> hello(name)
        False -> not_found()
      }
    _, _ -> not_found()
  }
}

fn hello(name: BitArray) -> midgard.Response {
  midgard.Response(200, <<"hello, ":utf8, name:bits, "!":utf8>>)
}

fn not_found() -> midgard.Response {
  midgard.Response(404, <<"Not found\n":utf8>>)
}

fn valid_name(name: BitArray) -> Bool {
  case name {
    <<>> -> False
    _ -> no_slash(name)
  }
}

fn no_slash(name: BitArray) -> Bool {
  case name {
    <<>> -> True
    <<"/":utf8, _rest:bits>> -> False
    <<_byte, rest:bits>> -> no_slash(rest)
    _ -> False
  }
}
