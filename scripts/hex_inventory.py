#!/usr/bin/env python3
"""Source-level survey of most-downloaded Hex packages; not a BEAM/runtime audit."""

import argparse
import io
import re
import tarfile
import urllib.request
from datetime import date

API = "https://hex.pm/api/packages?sort=downloads&page=1&per_page={}"
TARBALL = "https://repo.hex.pm/tarballs/{}-{}.tar"
BIF = re.compile(rb"(?:\berlang:|:erlang\.)([a-z][a-zA-Z0-9_]*)(?:\s*\(|/\d+)")
SERVICES = re.compile(rb"(?::|\b)(ets|persistent_term|crypto|ssl|gen_tcp|gen_udp|file|os|application|gen_server|maps)(?::|\.)[a-z][a-zA-Z0-9_]*")
NIF = re.compile(rb"(?:load_nif\s*\(|load_nif/2|\brustler\b|\belixir_make\b|\b@on_load\b|\b-on_load\s*\()", re.I)
SOURCE = (".ex", ".exs", ".erl", ".hrl", ".gleam")
NATIVE = (".c", ".cc", ".cpp", ".h", ".rs", ".so", ".dylib", ".dll")
MAX_TARBALL = 16_000_000
NATIVE_EXAMPLES = ("bcrypt_elixir", "argon2_elixir", "exqlite", "explorer", "rustler")


def get(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Midgard-source-inventory/1.0"})
    with urllib.request.urlopen(request, timeout=25) as response:
        data = response.read(MAX_TARBALL + 1)
    if len(data) > MAX_TARBALL:
        raise ValueError("tarball exceeds 16 MB survey limit")
    return data


def files_in_release(name, version):
    outer = tarfile.open(fileobj=io.BytesIO(get(TARBALL.format(name, version))))
    inner_bytes = outer.extractfile("contents.tar.gz").read(MAX_TARBALL + 1)
    if len(inner_bytes) > MAX_TARBALL:
        raise ValueError("contents exceeds 16 MB survey limit")
    inner = tarfile.open(fileobj=io.BytesIO(inner_bytes), mode="r:gz")
    if len(inner.getmembers()) > 5000:
        raise ValueError("too many source files")
    for member in inner:
        if not member.isfile():
            continue
        if member.name.endswith(SOURCE) and member.size <= 300_000:
            yield member.name, inner.extractfile(member).read(300_001)
        else:
            yield member.name, b""


def survey(package):
    name = package["name"]
    version = package["latest_stable_version"]
    bifs, services, native, nif, priv = set(), set(), [], [], []
    source_files = 0
    for path, data in files_in_release(name, version):
        if path.endswith(NATIVE) or path.startswith(("c_src/", "native/")):
            native.append(path)
        if path.startswith("priv/"):
            priv.append(path)
        if not data:
            continue
        source_files += 1
        bifs.update(item.decode("ascii") for item in BIF.findall(data))
        services.update(item.decode("ascii") for item in SERVICES.findall(data))
        if NIF.search(data):
            nif.append(path)
    return dict(name=name, version=version, downloads=package["downloads"]["all"],
                bifs=sorted(bifs), services=sorted(services), native=native, nif=nif,
                priv=priv, source_files=source_files)


def render(rows, failures, limit, examples):
    lines = ["# Hex package compatibility: source-level inventory", "",
             f"Snapshot: {date.today().isoformat()}; Hex API `sort=downloads` top {limit} by cumulative downloads, latest stable release tarballs.",
             "Run `python3 scripts/hex_inventory.py --limit 20 --output docs/hex-compatibility-inventory.md` to refresh.",
             "", "**Not a NIF/BIF admission verdict.** This scans published source only: direct `erlang:`/`:erlang.` calls,",
             "references to selected OTP services, native file paths, and NIF-related text markers.",
             "Unqualified Erlang BIFs, generated BEAM imports/opcodes, dynamic calls, transitive dependencies,",
             "compile-time-only calls, and native binaries outside the release cannot be determined from this scan.",
             "`priv/` counts matter because Midgard does not currently bundle runtime resources.", "",
             "| Rank | Package (latest stable) | Total downloads | Direct `erlang` calls observed | Native/NIF signals | `priv/` files | OTP service refs |",
             "| ---: | --- | ---: | --- | --- | ---: | --- |"]
    for row in rows:
        i = row["rank"]
        bifs = ", ".join(f"`{b}`" for b in row["bifs"]) or "none found"
        signals = []
        if row["native"]:
            signals.append(f"{len(row['native'])} native paths")
        if row["nif"]:
            signals.append("NIF-related text in " + ", ".join(f"`{p}`" for p in row["nif"][:3]))
        services = ", ".join(f"`{s}`" for s in row["services"]) or "none found"
        lines.append(f"| {i} | `{row['name']}` {row['version']} | {row['downloads']:,} | {bifs} | {'; '.join(signals) or 'none found'} | {len(row['priv'])} | {services} |")
    native_signals = sum(bool(row["native"] or row["nif"]) for row in rows)
    resources = [row["name"] for row in rows if row["priv"]]
    lines.extend(["", "## Observations", "",
                  f"- {native_signals} of {len(rows)} retrieved top packages showed native paths or NIF-related text in their own release. This is **not** a claim that their full dependency graphs are NIF-free.",
                  f"- `priv/` runtime-resource paths appeared in: {', '.join('`' + name + '`' for name in resources) or 'none found'}; Midgard currently refuses them.",
                  "- Direct calls suggest several BIF work areas: term/binary conversion (`term_to_binary`, `binary_to_term`, `float_to_binary`), time/timers (`monotonic_time`, `start_timer`, `cancel_timer`), process/monitoring (`monitor`, `demonitor`, `process_info`), and reflection (`function_exported`, `system_info`). Exact MFA/arity and reachability require compiled BEAM inspection.",
                  "- Some packages call OTP services such as `crypto` even without owning NIF sources; their implementation may depend on OTP native code that libbeam does not provide. Source-only NIF counts do not cover that dependency.",
                  "- NIF-backed guest packages cannot be made compatible by packaging a shared library: libbeam has no guest NIF loader. They need a separately designed, explicitly granted host operation or a BEAM-only alternative; never replace them with silent stubs.",
                  "", "## Illustrative native packages (not ranked in the top-20 list)", "",
                  "These selected packages show what a source-level native signal looks like; they are **not** a prevalence estimate.",
                  "Rustler is build tooling; its template sources alone do not mean the Rustler package loads a NIF at runtime.", "",
                  "| Package | Native source paths | NIF-related source | Observed direct `erlang` calls |",
                  "| --- | ---: | --- | --- |"])
    for row in examples:
        lines.append(f"| `{row['name']}` {row['version']} | {len(row['native'])} | "
                     f"{', '.join('`' + p + '`' for p in row['nif'][:3]) or 'none found'} | "
                     f"{', '.join('`' + b + '`' for b in row['bifs']) or 'none found'} |")
    if failures:
        lines.extend(["", "## Retrieval failures", ""])
        lines.extend(f"- `{name}`: {error}" for name, error in failures)
    lines.extend(["", "## Follow-up", "",
                  "1. For any candidate worker dependency, resolve its full locked runtime graph, build it with the intended OTP/toolchain, and scan actual BEAM imports and opcodes (including generated code).",
                  "2. Separate true `load_nif` and native resources from source-only hints; inspect build scripts and transitive dependencies before claiming NIF-free packaging.",
                  "3. Compare required BIF MFA/arity and OTP service imports against the tested libbeam revision. Prove whole-group admission and real invocation separately; never silently drop a dependency.", ""])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--output", help="write Markdown report here; otherwise print it")
    args = parser.parse_args()
    if not 1 <= args.limit <= 100:
        parser.error("limit must be 1..100")
    import json
    packages = json.loads(get(API.format(args.limit)))
    rows, examples, failures = [], [], []
    for rank, package in enumerate(packages, 1):
        try:
            row = survey(package)
            row["rank"] = rank
            rows.append(row)
        except (OSError, ValueError, KeyError, tarfile.TarError) as error:
            failures.append((package["name"], str(error)))
    for name in NATIVE_EXAMPLES:
        try:
            package = json.loads(get("https://hex.pm/api/packages/" + name))
            examples.append(survey(package))
        except (OSError, ValueError, KeyError, tarfile.TarError) as error:
            failures.append((name, str(error)))
    report = render(rows, failures, args.limit, examples)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as output:
            output.write(report)
    else:
        print(report)


if __name__ == "__main__":
    main()
