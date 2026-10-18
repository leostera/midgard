# HolaMundo

This example handles `GET /hello/:name` and responds `Hello from <name>`. It does **not** serve `/` or `/hello`. Dependencies use Git revision 55c3c12c592909a05d67b2a7bdb09c03606e261e of https://github.com/leostera/midgard.git. Install the current CLI archive before deploying:

```sh
mix archive.install github leostera/midgard --app midgard_cli --sparse apps/midgard_cli --force
cd examples/hola_mundo
mix deps.get
mix test
mix midgard.deploy
# Append /hello/joe to the Route prefix printed by deploy. For example:
curl https://hola-mundo-0123456789abcdef.midgard.leostera.dev/hello/joe
```

Run the archive install from the repository root; if you're already in this directory, omit the `cd`. Replace the example route ID with the one printed by your deployment. To inspect the artifact locally, run `mix midgard.build` then `mix packer.inspect hola_mundo.midgard`. A successful deployment response means the exact shipment was verified and admitted by the public libbeam host.
