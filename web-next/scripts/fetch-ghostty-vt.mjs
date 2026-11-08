/*
 * Fetches Ghostty's release libghostty-vt wasm into public/ghostty-vt/
 * (gitignored), where the drawer's canvas terminal loads it same-origin: the
 * release host sends no CORS headers. The file must match the SHA-256 pinned
 * in src/components/terminal/vt/ghostty-vt.ts, recorded after verifying
 * Ghostty's minisign signature on the release. `pnpm build` runs this first,
 * so no build ships without the verified file; CI also runs it before the
 * unit tests so the wasm-backed tests run on every PR.
 */
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const source = await readFile(join(root, "src/components/terminal/vt/ghostty-vt.ts"), "utf8");
const pin = (field) => {
	const match = source.match(new RegExp(`\\b${field}: "([^"]+)"`));
	if (!match) throw new Error(`GHOSTTY_VT_RELEASE.${field} not found in ghostty-vt.ts`);
	return match[1];
};
const [origin, file, sha256, servedFrom] = ["origin", "file", "sha256", "servedFrom"].map(pin);
const target = join(root, "public", servedFrom, file);
await mkdir(dirname(target), { recursive: true });

const existing = await readFile(target).catch(() => null);
if (existing && digest(existing) === sha256) {
	console.log(`ok      ${file} (cached) sha256=${sha256}`);
} else {
	const response = await fetch(`${origin}${file}`);
	if (!response.ok) throw new Error(`${origin}${file}: HTTP ${response.status}`);
	const bytes = Buffer.from(await response.arrayBuffer());
	const actual = digest(bytes);
	if (actual !== sha256) throw new Error(`${file}: sha256 ${actual}, expected ${sha256}`);
	await writeFile(target, bytes);
	console.log(`fetched ${file} ${bytes.length} bytes sha256=${actual}`);
}

function digest(bytes) {
	return createHash("sha256").update(bytes).digest("hex");
}
