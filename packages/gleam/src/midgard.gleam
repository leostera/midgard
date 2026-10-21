/// A framework request passed to a worker handler.
pub type Request {
  Request(
    method: BitArray,
    path: BitArray,
    query_string: BitArray,
    headers: List(#(BitArray, BitArray)),
    body: BitArray,
  )
}

/// A framework response returned by a worker handler.
pub type Response {
  Response(status: Int, body: BitArray)
}

/// Runs a request handler over a `midgard.bytes.v1` frame.
/// Malformed frames receive a 400 response.
pub fn serve(input: BitArray, handler: fn(Request) -> Response) -> BitArray {
  case decode_request(input) {
    Ok(request) -> encode_response(handler(request))
    Error(Nil) -> encode_response(Response(400, <<"Bad request\n":utf8>>))
  }
}

/// Decodes a `midgard.bytes.v1` request frame.
pub fn decode_request(input: BitArray) -> Result(Request, Nil) {
  case input {
    <<
      1,
      method_size:8,
      path_size:16,
      query_size:16,
      header_count:8,
      body_size:16,
      rest:bits,
    >>
      if method_size > 0 && path_size > 0
    ->
      case rest {
        <<
          method:bytes-size(method_size),
          path:bytes-size(path_size),
          query_string:bytes-size(query_size),
          headers_and_body:bits,
        >> ->
          case decode_headers(headers_and_body, header_count, []) {
            Ok(#(headers, body)) ->
              case body {
                <<body:bytes-size(body_size)>> ->
                  Ok(Request(method:, path:, query_string:, headers:, body:))
                _ -> Error(Nil)
              }
            Error(Nil) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn decode_headers(
  bytes: BitArray,
  count: Int,
  acc: List(#(BitArray, BitArray)),
) -> Result(#(List(#(BitArray, BitArray)), BitArray), Nil) {
  case count, bytes {
    0, _ -> Ok(#(reverse(acc, []), bytes))
    _,
      <<
        name_size:8,
        value_size:16,
        name:bytes-size(name_size),
        value:bytes-size(value_size),
        rest:bits,
      >>
    -> decode_headers(rest, count - 1, [#(name, value), ..acc])
    _, _ -> Error(Nil)
  }
}

fn reverse(list: List(a), acc: List(a)) -> List(a) {
  case list {
    [] -> acc
    [first, ..rest] -> reverse(rest, [first, ..acc])
  }
}

/// Encodes a response as a `midgard.bytes.v1` binary frame.
pub fn encode_response(response: Response) -> BitArray {
  case response {
    Response(status, body) -> <<2, status:16, byte_size(body):16, body:bits>>
  }
}

@external(erlang, "erlang", "byte_size")
fn byte_size(bytes: BitArray) -> Int
