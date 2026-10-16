# Only pure Elixir BEAMs are compiled on the matching OTP/Elixir toolchain.
# No emulated OTP invocation or Docker daemon runs inside the deployed image.
FROM registry.cloudflare.com/0f436d2aabf1f872be90b8dd9d5715e6/midgard-runtime@sha256:6f3e271f15ac28dcd3c39bd64703654934ee1d2501f2de1b9515c684201b5504
COPY ebin/ /opt/midgard/_build/prod/lib/midgard_platform/ebin/
COPY application.ex /opt/midgard/apps/midgard_platform/lib/midgard/platform/application.ex
COPY page.ex /opt/midgard/apps/midgard_platform/lib/midgard/platform/page.ex
ARG MIDGARD_SOURCE_COMMIT
ENV MIDGARD_SOURCE_COMMIT=${MIDGARD_SOURCE_COMMIT}
WORKDIR /opt/midgard
EXPOSE 4000
CMD ["mix", "run", "--no-compile", "--no-halt"]
