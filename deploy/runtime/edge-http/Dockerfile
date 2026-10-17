# Only pure Elixir BEAMs are compiled on the matching OTP/Elixir toolchain.
# No emulated OTP invocation or Docker daemon runs inside the deployed image.
FROM registry.cloudflare.com/0f436d2aabf1f872be90b8dd9d5715e6/midgard-runtime@sha256:ee3504528f7f80f0c24f8161c7dd8a46f8d2a3a9ffa787b145a9adc823127676
COPY ebin/ /opt/midgard/_build/prod/lib/midgard_platform/ebin/
COPY packer-ebin/ /opt/midgard/_build/prod/lib/packer/ebin/
COPY mix.exs /opt/midgard/apps/midgard_platform/mix.exs
COPY application.ex /opt/midgard/apps/midgard_platform/lib/midgard/platform/application.ex
COPY page.ex /opt/midgard/apps/midgard_platform/lib/midgard/platform/page.ex
COPY app.css /opt/midgard/apps/midgard_platform/priv/static/app.css
ARG MIDGARD_SOURCE_COMMIT
ENV MIDGARD_SOURCE_COMMIT=${MIDGARD_SOURCE_COMMIT}
WORKDIR /opt/midgard
EXPOSE 4000
CMD ["mix", "run", "--no-compile", "--no-halt"]
