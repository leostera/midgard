// This extractor is run in a *different* offline VM from the compiler. Never
// trust tar paths, links, duplicate entries or compiler-supplied checksums.
// Shipment.read/1 verifies the materialized bytes again before native admission.
const unpackShipment = `import hashlib, json, os, re, tarfile
archive = '/tmp/shipment.tar'
root = '/tmp/shipment.midgard'
with tarfile.open(archive, 'r:') as bundle:
    members = bundle.getmembers()
    if len(members) < 3 or len(members) > 514:
        raise ValueError('unexpected tar entry count')
    names = [m.name for m in members]
    if len(names) != len(set(names)) or 'manifest.json' not in names or 'modules' not in names:
        raise ValueError('missing or duplicate tar entries')
    manifest_member = bundle.getmember('manifest.json')
    if not manifest_member.isfile() or not 0 < manifest_member.size <= 262144:
        raise ValueError('invalid manifest file')
    manifest = json.loads(bundle.extractfile(manifest_member).read())
    records = manifest.get('modules')
    if manifest.get('format') != 'midgard.beam' or not isinstance(records, list) or not 0 < len(records) <= 512:
        raise ValueError('invalid shipment manifest')
    expected = {'manifest.json', 'modules'}
    total = 0
    os.makedirs(root + '/modules', exist_ok=False)
    with open(root + '/manifest.json', 'wb') as out:
        out.write(bundle.extractfile(manifest_member).read())
    for record in records:
        name = record.get('name')
        if not isinstance(name, str) or not re.fullmatch(r'(?:Elixir\\.[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)*|[a-z][A-Za-z0-9_@]*)', name):
            raise ValueError('invalid module name')
        path = 'modules/' + name + '.beam'
        if record.get('path') != path or path in expected or path not in names:
            raise ValueError('invalid module path')
        member = bundle.getmember(path)
        size = record.get('size')
        if not member.isfile() or type(size) is not int or not 0 < size <= 2000000 or member.size != size:
            raise ValueError('invalid module size or type')
        total += size
        if total > 32000000:
            raise ValueError('oversized shipment')
        data = bundle.extractfile(member).read()
        if hashlib.sha256(data).hexdigest() != record.get('sha256'):
            raise ValueError('module checksum mismatch')
        with open(root + '/' + path, 'xb') as out:
            out.write(data)
        expected.add(path)
    if set(names) != expected or not bundle.getmember('modules').isdir():
        raise ValueError('undeclared tar entries')
print('verified ' + str(len(records)) + ' BEAM files')
`;

// A fresh Elixir VM owns its own native Port and Isolate. This is a deliberately
// slow, per-call admission milestone; no Isolate handle is claimed to survive a
// restart. Replace it only after the long-lived, per-worker control API is built.
const callProbe = `{:ok, _pid} = Midgard.Platform.start_link()
{:ok, digest} = Midgard.Platform.deploy("probe", "/tmp/shipment.midgard", defer_denied_nif: true)
request = %Midgard.Request{method: "GET", path: "/hello/joe", query_string: "", headers: [], body: ""}
{:ok, input} = Midgard.Protocol.request(request)
{:ok, reply} = Midgard.Platform.call("probe", input)
{:ok, {status, body}} = Midgard.Protocol.decode_response(reply)
IO.puts("MIDGARD_PROBE:" <> Base.encode64(:json.encode(%{digest: digest, status: status, body: body})))
`;

export async function executeShipment(container: Container, request: Request): Promise<Response> {
		const contentLength = Number(request.headers.get("content-length"));
		if (!Number.isFinite(contentLength) || contentLength < 1 || contentLength > 40_000_000) {
			return new Response("Invalid shipment size", { status: 413 });
		}
		const archive = await request.arrayBuffer();
		if (archive.byteLength !== contentLength) return new Response("Invalid shipment length", { status: 400 });
		if (!container.running) {
			container.start({
				image: container.images.native,
				instance: "standard-1",
				enableInternet: false,
				entrypoint: ["/usr/bin/sleep", "infinity"],
			});
		}
		await container.setInactivityTimeout(120_000);

		const upload = await container.exec(["/usr/bin/tee", "/tmp/shipment.tar"], { stdin: "pipe", stdout: "ignore" });
		const writer = upload.stdin?.getWriter();
		if (!writer) throw new Error("Native shipment upload stream unavailable");
		await writer.write(new Uint8Array(archive));
		await writer.close();
		if ((await upload.output()).exitCode !== 0) throw new Error("Native shipment upload failed");

		await container.exec(["/usr/bin/rm", "-rf", "/tmp/shipment.midgard"]);
		const unpack = await container.exec(["/usr/bin/python3", "-c", unpackShipment]);
		const unpacked = await unpack.output();
		if (unpacked.exitCode !== 0) throw new Error("Native shipment rejected before admission");

		const invoke = await container.exec([
			"/usr/bin/timeout", "-k", "5s", "65s", "/usr/local/bin/mix", "run", "--no-start", "-e", callProbe,
		], { cwd: "/opt/midgard" });
		const result = await invoke.output();
		if (result.exitCode !== 0) throw new Error(`Native admission or invocation exited ${result.exitCode}: ${new TextDecoder().decode(result.stderr).slice(0, 2000)}`);
		const match = new TextDecoder().decode(result.stdout).match(/MIDGARD_PROBE:([A-Za-z0-9+/=]+)/);
		if (!match) throw new Error("Native process did not return executed bytes");
		const payload: unknown = JSON.parse(atob(match[1]));
		return Response.json(payload);
}
