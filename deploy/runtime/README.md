# Native runtime image: staging prerequisite

`build-image.sh` creates a `linux/amd64` image from **git-archived tracked
sources only**, pinning libbeam to `5a8c663b819d5d24bde4fbbb7f7099385f090890`
and the Elixir compiler/runtime to `13299af2b91a6aff7e430f25849f586c02b3231f`.
The image tag is the Midgard source commit; no credential or working-tree file
enters the build context. The manually dispatched `Build runtime image` GitHub
Actions workflow runs the OTP 29 BIF test, builds on an amd64 runner, and
uploads the image as a one-day artifact. Download it with `gh run download`,
load it with `docker load`, then publish it with `cf containers push` before
updating the edge image's pinned base digest.

```sh
LIBBEAM_SOURCE=/path/to/leostera/libbeam \
ELIXIR_SOURCE=/path/to/elixir \
  deploy/runtime/build-image.sh
```

**Not a public deployment:** this image only establishes that the native
backend can be built for Linux. The application still binds to loopback,
requires a local Docker daemon to compile uploaded source (not included in
this image), and retains drafts/shipments on an ephemeral filesystem. Do not
route public creation, editing, or invocation traffic to it. A separate
untrusted compiler job, per-worker runtime isolation, durable Artifacts-backed
state, recovery, and abuse controls are required first.

On macOS/arm64, OrbStack's emulation currently fails to start the pinned
amd64 OTP VM (`prim_tty`/`erlang:nif_error`); use the amd64 CI workflow rather
than treating that as evidence about native Linux runtime compatibility.
