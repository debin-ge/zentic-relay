FROM hexpm/elixir:1.20.2-erlang-29.0.2-debian-bookworm-20260623-slim AS build
WORKDIR /app
ENV MIX_ENV=prod
COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get --only prod
COPY config config
COPY lib lib
RUN mix compile && mix release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 libsctp1 openssl ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/_build/prod/rel/zentic_relay ./
ENV HOME=/app \
    ZENTIC_RELAY_HOST=0.0.0.0 \
    ZENTIC_RELAY_PORT=4000 \
    ZENTIC_RELAY_DRAIN=false
EXPOSE 4000
ENTRYPOINT ["/app/bin/zentic_relay"]
CMD ["start"]
