# Hex package compatibility: source-level inventory

Snapshot: 2026-10-13; Hex API `sort=downloads` top 20 by cumulative downloads, latest stable release tarballs.
Run `python3 scripts/hex_inventory.py --limit 20 --output docs/hex-compatibility-inventory.md` to refresh.

**Not a NIF/BIF admission verdict.** This scans published source only: direct `erlang:`/`:erlang.` calls,
references to selected OTP services, native file paths, and NIF-related text markers.
Unqualified Erlang BIFs, generated BEAM imports/opcodes, dynamic calls, transitive dependencies,
compile-time-only calls, and native binaries outside the release cannot be determined from this scan.
`priv/` counts matter because Midgard does not currently bundle runtime resources.

| Rank | Package (latest stable) | Total downloads | Direct `erlang` calls observed | Native/NIF signals | `priv/` files | OTP service refs |
| ---: | --- | ---: | --- | --- | ---: | --- |
| 1 | `jason` 1.4.5 | 213,057,997 | `binary_to_float`, `float_to_binary`, `split_binary` | none found | 0 | `maps` |
| 2 | `certifi` 2.17.0 | 178,406,752 | none found | none found | 1 | `file`, `ssl` |
| 3 | `idna` 7.1.0 | 176,122,881 | `error`, `exit` | none found | 0 | none found |
| 4 | `ssl_verify_fun` 1.1.7 | 174,407,493 | none found | none found | 0 | `crypto`, `file` |
| 5 | `parse_trans` 3.4.2 | 173,630,069 | `error`, `fun_info`, `process_info` | none found | 0 | `application`, `file`, `maps` |
| 6 | `hackney` 4.8.5 | 173,451,868 | `cancel_timer`, `decode_packet`, `demonitor`, `error`, `function_exported`, `get_stacktrace`, `is_process_alive`, `monitor`, `monotonic_time`, `port_connect`, `start_timer`, `system_time` | none found | 0 | `application`, `crypto`, `ets`, `file`, `gen_server`, `gen_tcp`, `gen_udp`, `maps`, `os`, `ssl` |
| 7 | `unicode_util_compat` 0.7.1 | 170,996,822 | `length`, `nif_error` | none found | 0 | none found |
| 8 | `mimerl` 1.5.0 | 167,201,098 | none found | none found | 0 | `file` |
| 9 | `plug` 1.20.3 | 166,768,981 | `phash2`, `raise`, `system_info`, `term_to_binary`, `unique_integer` | none found | 0 | `application`, `crypto`, `ets`, `file`, `gen_tcp`, `os`, `persistent_term`, `ssl` |
| 10 | `metrics` 2.5.0 | 164,904,153 | `error`, `function_exported`, `monitor` | none found | 0 | `application`, `ets`, `gen_server` |
| 11 | `gettext` 1.0.2 | 164,674,201 | `md5` | none found | 0 | none found |
| 12 | `telemetry` 1.4.2 | 164,663,583 | `error`, `fun_info`, `get_stacktrace`, `is_atom`, `make_ref`, `monotonic_time`, `raise`, `system_time` | none found | 0 | `ets`, `file`, `gen_server`, `maps`, `persistent_term` |
| 13 | `ranch` 2.3.0 | 163,539,816 | `cancel_timer`, `crc32`, `demonitor`, `function_exported`, `monitor`, `send`, `send_after`, `start_timer` | none found | 0 | `application`, `ets`, `file`, `gen_server`, `gen_tcp`, `maps`, `ssl` |
| 14 | `mime` 2.0.7 | 162,733,188 | none found | none found | 0 | none found |
| 15 | `decimal` 3.2.0 | 162,454,666 | `binary_to_integer`, `float`, `float_to_binary`, `integer_to_binary`, `is_map_key`, `map_get` | none found | 0 | none found |
| 16 | `plug_crypto` 2.2.0 | 158,464,030 | `binary_to_term`, `element`, `term_to_binary` | none found | 0 | `crypto`, `ets`, `maps` |
| 17 | `phoenix` 1.8.15 | 157,221,950 | `garbage_collect`, `md5`, `phash2`, `raise`, `system_flag`, `system_info` | none found | 89 | `application`, `crypto`, `ets`, `file`, `maps`, `os`, `persistent_term` |
| 18 | `db_connection` 2.10.2 | 151,210,730 | `cancel_timer`, `element`, `monotonic_time`, `phash2`, `process_info`, `raise`, `start_timer`, `tuple_size` | none found | 0 | `ets` |
| 19 | `cowboy` 2.20.0 | 150,016,953 | `cancel_timer`, `delete_element`, `function_exported`, `monotonic_time`, `phash2`, `raise`, `send_after`, `start_timer`, `trace`, `trace_info`, `trace_pattern`, `universaltime` | none found | 0 | `application`, `crypto`, `ets`, `file`, `gen_server`, `gen_udp`, `maps`, `os`, `persistent_term`, `ssl` |
| 20 | `ecto` 3.14.2 | 148,789,350 | `float`, `phash2`, `process_info` | none found | 0 | `application`, `crypto`, `ets`, `file`, `maps`, `persistent_term` |

## Observations

- 0 of 20 retrieved top packages showed native paths or NIF-related text in their own release. This is **not** a claim that their full dependency graphs are NIF-free.
- `priv/` runtime-resource paths appeared in: `certifi`, `phoenix`; Midgard currently refuses them.
- Direct calls suggest several BIF work areas: term/binary conversion (`term_to_binary`, `binary_to_term`, `float_to_binary`), time/timers (`monotonic_time`, `start_timer`, `cancel_timer`), process/monitoring (`monitor`, `demonitor`, `process_info`), and reflection (`function_exported`, `system_info`). Exact MFA/arity and reachability require compiled BEAM inspection.
- Some packages call OTP services such as `crypto` even without owning NIF sources; their implementation may depend on OTP native code that libbeam does not provide. Source-only NIF counts do not cover that dependency.
- NIF-backed guest packages cannot be made compatible by packaging a shared library: libbeam has no guest NIF loader. They need a separately designed, explicitly granted host operation or a BEAM-only alternative; never replace them with silent stubs.

## Illustrative native packages (not ranked in the top-20 list)

These selected packages show what a source-level native signal looks like; they are **not** a prevalence estimate.
Rustler is build tooling; its template sources alone do not mean the Rustler package loads a NIF at runtime.

| Package | Native source paths | NIF-related source | Observed direct `erlang` calls |
| --- | ---: | --- | --- |
| `bcrypt_elixir` 3.3.2 | 3 | `lib/bcrypt/base.ex`, `mix.exs` | `load_nif`, `nif_error` |
| `argon2_elixir` 4.1.3 | 21 | `lib/argon2/base.ex`, `mix.exs` | `load_nif`, `nif_error` |
| `exqlite` 0.42.0 | 4 | `lib/exqlite/sqlite3_nif.ex`, `mix.exs` | `list_to_pid`, `load_nif`, `nif_error` |
| `explorer` 0.13.0 | 19 | `lib/explorer/polars_backend/native.ex`, `mix.exs` | `nif_error` |
| `rustler` 0.38.0 | 1 | `lib/mix/tasks/rustler.new.ex`, `lib/rustler/compiler.ex`, `lib/rustler/compiler/config.ex` | `hd`, `load_nif` |

## Follow-up

1. For any candidate worker dependency, resolve its full locked runtime graph, build it with the intended OTP/toolchain, and scan actual BEAM imports and opcodes (including generated code).
2. Separate true `load_nif` and native resources from source-only hints; inspect build scripts and transitive dependencies before claiming NIF-free packaging.
3. Compare required BIF MFA/arity and OTP service imports against the tested libbeam revision. Prove whole-group admission and real invocation separately; never silently drop a dependency.
