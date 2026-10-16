@external(erlang, "erlang", "byte_size")
fn byte_size(bytes: BitArray) -> Int

pub fn response(status: Int, body: BitArray) -> BitArray {
  <<2, status:16, byte_size(body):16, body:bits>>
}

pub fn hello(name: BitArray) -> BitArray {
  <<"Hello from ":utf8, name:bits, 10>>
}
