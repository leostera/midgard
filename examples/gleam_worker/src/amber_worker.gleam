import amber_helper

// The same midgard.bytes.v1 HTTP-shaped request/response envelope as Elixir.
// The host frames requests; this Isolate only receives and returns BitArrays.
pub fn handle(input: BitArray) -> BitArray {
  case input {
    <<
      1,
      method_size:8,
      path_size:16,
      query_size:16,
      header_count:8,
      body_size:16,
      rest:bits,
    >> -> {
      case rest {
        <<
          method:bytes-size(method_size),
          path:bytes-size(path_size),
          _query:bytes-size(query_size),
          headers_and_body:bits,
        >> -> {
          case has_body(headers_and_body, header_count, body_size) {
            True -> dispatch(method, path)
            False -> amber_helper.response(400, <<"worker error\n":utf8>>)
          }
        }
        _ -> amber_helper.response(400, <<"worker error\n":utf8>>)
      }
    }
    _ -> amber_helper.response(400, <<"worker error\n":utf8>>)
  }
}

fn has_body(bytes: BitArray, count: Int, body_size: Int) -> Bool {
  case count {
    0 ->
      case bytes {
        <<_body:bytes-size(body_size)>> -> True
        _ -> False
      }
    _ ->
      case bytes {
        <<
          name_size:8,
          value_size:16,
          _name:bytes-size(name_size),
          _value:bytes-size(value_size),
          rest:bits,
        >> -> has_body(rest, count - 1, body_size)
        _ -> False
      }
  }
}

fn dispatch(method: BitArray, path: BitArray) -> BitArray {
  case method, path {
    <<"GET":utf8>>, <<"/hello":utf8>> ->
      amber_helper.response(200, <<"Hello from Gleam!\n":utf8>>)
    <<"GET":utf8>>, <<"/hello/":utf8, name:bits>> ->
      case name {
        <<>> -> not_found()
        _ ->
          case valid_name(name) {
            True -> amber_helper.response(200, amber_helper.hello(name))
            False -> not_found()
          }
      }
    _, _ -> not_found()
  }
}

fn valid_name(name: BitArray) -> Bool {
  case name {
    <<>> -> True
    <<"/":utf8, _rest:bits>> -> False
    <<_byte, rest:bits>> -> valid_name(rest)
    _ -> False
  }
}

fn not_found() -> BitArray {
  amber_helper.response(404, <<"Not found\n":utf8>>)
}
