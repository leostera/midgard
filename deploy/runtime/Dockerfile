# Bazel's published image supplies the pinned binary; libbeam's generators also
# need the same OTP/Elixir toolchain that will run the application.
FROM gcr.io/bazel-public/bazel@sha256:6158d62576c99301611a7d072aa37e2f721b6bc9cd7e28dc33c85f4719d93540 AS bazel
FROM hexpm/elixir@sha256:8c1b44690f7b337328869b7bcfa5b5ecc816d63f8cca57467177b6d84cca8565 AS native
COPY --from=bazel /usr/local/bin/bazel /usr/local/bin/bazel
WORKDIR /build/libbeam
COPY libbeam-source/ ./
# GCC diagnoses style and signedness in upstream C more strictly than the
# macOS build; retain warnings, without changing libbeam admission behavior.
RUN bazel build --copt=-D_POSIX_C_SOURCE=200809L \
    --copt=-Wno-error=misleading-indentation \
    --copt=-Wno-error=sign-compare //libbeam:libbeam //libbeam:core
COPY midgard-source/apps/libbeam_elixir/native/libbeam_host.cpp /build/libbeam_host.cpp
RUN c++ -std=c++17 -O2 -I/build/libbeam/libbeam/include \
    /build/libbeam_host.cpp bazel-bin/libbeam/liblibbeam.a \
    bazel-bin/libbeam/libcore.a -lz -pthread -o /build/libbeam_host

# Compile against the same Elixir and OTP versions as the pinned compiler.
FROM hexpm/elixir@sha256:8c1b44690f7b337328869b7bcfa5b5ecc816d63f8cca57467177b6d84cca8565
COPY elixir-source/ /opt/elixir-source/
WORKDIR /opt/elixir-source
RUN make -j2 compile && make install && \
    elixir -e 'unless System.version() == "1.21.0-dev", do: System.halt(1)'

WORKDIR /opt/midgard
COPY midgard-source/ ./
COPY --from=native /build/libbeam_host /opt/midgard/apps/libbeam_elixir/priv/libbeam_host
ARG MIDGARD_SOURCE_COMMIT
ENV MIDGARD_SOURCE_COMMIT=${MIDGARD_SOURCE_COMMIT} MIX_ENV=prod
RUN mix local.hex --force && mix deps.get && mix compile && \
    test -x apps/libbeam_elixir/priv/libbeam_host

# This image is only a native-host staging milestone. The existing application
# binds loopback and cannot compile uploads here: no Docker daemon is included.
EXPOSE 4000
CMD ["mix", "run", "--no-halt"]
