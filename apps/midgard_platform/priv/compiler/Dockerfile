# Runtime BEAM providers must come from the same pinned compiler environment.
FROM elixir@sha256:d170fadffd75b36146ff40b6e8d5cc881c59d136ae5a2c34a1b394ec33b6cffa
LABEL org.midgard.elixir-source="13299af2b91a6aff7e430f25849f586c02b3231f"
COPY elixir/ /opt/elixir-source/
WORKDIR /opt/elixir-source
RUN make -j2 compile && make install && elixir -e 'unless System.version() == "1.21.0-dev", do: System.halt(1)'
WORKDIR /workspace
