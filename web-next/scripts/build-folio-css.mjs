/*
 * Compiles Folio's Tailwind source contract into a standalone distributable
 * stylesheet. Consumers receive plain scoped CSS and need no Tailwind tooling.
 */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import tailwindcss from "@tailwindcss/postcss";
import postcss from "postcss";

const WEB_NEXT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = path.join(WEB_NEXT, "packages", "folio", "src", "styles.css");
const output = path.join(WEB_NEXT, "packages", "folio", "dist", "styles.css");

await mkdir(path.dirname(output), { recursive: true });
const result = await postcss([tailwindcss({ optimize: true })]).process(
	await readFile(source, "utf8"),
	{
		from: source,
		to: output,
		map: { inline: false, annotation: true, sourcesContent: true },
	},
);
await writeFile(output, result.css);
if (result.map) await writeFile(`${output}.map`, result.map.toString());
console.log(`built ${path.relative(WEB_NEXT, output)} (${Buffer.byteLength(result.css)} bytes)`);
