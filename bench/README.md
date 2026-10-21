# Deploy benchmarks

The landing page's hero compares how long the same hello-world worker takes to
go from the deploy command to a first response from the new version.

- **Midgard:** `scripts/measure-deploy.sh elixir gleam erlang` deploys to the
  public demo. "Live" includes DNS for the new per-deploy hostname.
- **Cloudflare Containers:** `bench/cloudflare-containers/measure.sh ARTIFACT_DIR 3`
  builds an `erlang:29-slim` image with the worker's exact Midgard modules and
  `container/midgard_http.erl` (a dependency-free HTTP front that calls the
  same entrypoint), runs `cf deploy`, and polls the existing `workers.dev` URL
  until the new image (matched by `x-image-id`) answers. It then destroys the
  container and times a cold restart.
- **Local Docker:** `scripts/measure-container.sh` times `docker run` of a
  pre-pulled image. Useful only as a lower bound for boot time.

Medians of three runs each, October 2026, from a laptop over a home connection:

| | Midgard deploy | Midgard live | Containers deploy | Containers live | Containers cold restart |
| --- | --- | --- | --- | --- | --- |
| Elixir | 9.8 s | 15.4 s | 17.3 s | 186.3 s | 1.2 s |
| Gleam | 5.8 s | 11.7 s | 16.0 s | 119.3 s | 1.2 s |
| Erlang | 3.6 s | 13.8 s | 22.1 s | 181.9 s | 1.3 s |

Midgard numbers are for the 0.4.0 tooling from Hex, which tree-shakes Elixir
shipments (18.8 MB → 1.5 MB). Each run scaffolds a fresh project, but Packer's
shake cache (`~/Library/Caches/midgard_packer` on macOS) was warm. A machine's
first Elixir deploy fills that cache: 33.8 s to deploy and 40.1 s until live in
the run with the least load. Before tree shaking (0.3.0), Elixir took 78.3 s to
deploy and 84.6 s until live. Midgard's "live" time is mostly waiting for DNS
for the new hostname (5–11 s). The Containers images still bundled the
unshaken modules; their time is dominated by the rollout, not image size.

Most of the Containers time comes after `cf deploy` exits, while the new
version rolls out; individual runs ranged from 2 to 6 minutes. Once running, a
stopped container restarts in about a second.

`measure.sh` creates the `midgard-container-bench` Worker and container
application on the logged-in account. Delete both when done:

```sh
cd bench/cloudflare-containers
./node_modules/.bin/cf containers applications list   # find the bench app id
./node_modules/.bin/cf containers applications delete <id> --force
./node_modules/.bin/cf workers delete midgard-container-bench --force
```
