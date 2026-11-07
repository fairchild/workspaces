/*
 * Fetches Ghostty's release libghostty-vt wasm builds for the terminal-vt
 * spike (#1846) into public/dev/terminal-vt/, gitignored. Each file must match
 * the SHA-256 pinned in src/components/terminal/vt/ghostty-vt.ts, which was
 * recorded after verifying Ghostty's minisign signature on the release.
 */
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const source = await readFile(join(root, "src/components/terminal/vt/ghostty-vt.ts"), "utf8");
const origin = source.match(/origin: "([^"]+)"/)[1];
const builds = [...source.matchAll(/file: "([^"]+)",\s*sha256: "([0-9a-f]{64})"/g)];
const outDir = join(root, "public/dev/terminal-vt");
await mkdir(outDir, { recursive: true });

for (const [, file, sha256] of builds) {
	const target = join(outDir, file);
	const existing = await readFile(target).catch(() => null);
	if (existing && digest(existing) === sha256) {
		console.log(`ok      ${file} (cached)`);
		continue;
	}
	const response = await fetch(`${origin}${file}`);
	if (!response.ok) throw new Error(`${file}: HTTP ${response.status}`);
	const bytes = Buffer.from(await response.arrayBuffer());
	const actual = digest(bytes);
	if (actual !== sha256) throw new Error(`${file}: sha256 ${actual}, expected ${sha256}`);
	await writeFile(target, bytes);
	console.log(`fetched ${file} ${bytes.length} bytes sha256=${actual}`);
}

function digest(bytes) {
	return createHash("sha256").update(bytes).digest("hex");
}
