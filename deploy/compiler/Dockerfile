# Bootstraps from the already verified amd64 Elixir/OTP image. This image is
# used only in fresh, offline, disposable compiler VMs, never for serving calls.
FROM registry.cloudflare.com/0f436d2aabf1f872be90b8dd9d5715e6/midgard-runtime@sha256:6f3e271f15ac28dcd3c39bd64703654934ee1d2501f2de1b9515c684201b5504
WORKDIR /workspace
COPY apps/midgard_platform/priv/compiler/compile.exs /workspace/compile.exs
COPY apps/midgard/lib/midgard/request.ex /workspace/sdk/request.ex
COPY apps/midgard/lib/midgard/protocol.ex /workspace/sdk/protocol.ex
COPY apps/midgard/lib/midgard/worker.ex /workspace/sdk/worker.ex
RUN mkdir -p /output/modules
ENV HOME=/tmp MIX_ENV=prod
CMD ["/usr/bin/sleep", "infinity"]
