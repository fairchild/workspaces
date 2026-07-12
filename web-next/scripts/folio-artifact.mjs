/*
 * Canonical Folio release candidate: clean-build, stage, pack twice, inspect,
 * checksum, then install and build a standalone Next consumer from /tmp.
 */
import { createHash } from "node:crypto";
import {
	cp,
	mkdir,
	mkdtemp,
	readFile,
	realpath,
	rm,
	stat,
	writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
	createArtifactManifest,
	tarballFilename,
	validateBuildOutput,
	validatePackedArtifact,
} from "./folio-artifact-core.mjs";

const exec = promisify(execFile);
const WEB_NEXT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const PACKAGE = path.join(WEB_NEXT, "packages", "folio");
const ARTIFACTS = path.join(WEB_NEXT, "artifacts", "folio");
const STAGE = path.join(ARTIFACTS, "stage");
const RUN_A = path.join(ARTIFACTS, "pack-a");
const RUN_B = path.join(ARTIFACTS, "pack-b");
const PNPM = process.env.npm_execpath;

if (!PNPM) throw new Error("run this script through pnpm so npm_execpath is defined");

async function runPnpm(args, options = {}) {
	const javascriptEntrypoint = /\.[cm]?js$/.test(PNPM);
	return exec(javascriptEntrypoint ? process.execPath : PNPM, javascriptEntrypoint ? [PNPM, ...args] : args, {
		cwd: options.cwd ?? WEB_NEXT,
		env: { ...process.env, ...options.env },
		maxBuffer: 20 * 1024 * 1024,
	});
}

async function sha256(file) {
	return createHash("sha256").update(await readFile(file)).digest("hex");
}

async function stagePackage() {
	await runPnpm(["run", "clean", "folio-artifact"]);
	await runPnpm(["--filter", "@fairchild/folio", "build"]);
	await mkdir(STAGE, { recursive: true });
	await cp(path.join(PACKAGE, "dist"), path.join(STAGE, "dist"), {
		recursive: true,
	});
	for (const file of ["README.md", "LICENSE", "CHANGELOG.md"]) {
		await cp(path.join(PACKAGE, file), path.join(STAGE, file));
	}
	const sourceManifest = JSON.parse(
		await readFile(path.join(PACKAGE, "package.json"), "utf8"),
	);
	const manifest = createArtifactManifest(sourceManifest);
	const dist = path.join(PACKAGE, "dist");
	const distFiles = Object.fromEntries(
		await Promise.all(
			[
			"index.js",
			"conversation.js",
			"format.js",
			"theme.js",
			"theme-toggle.js",
			"testing.js",
			].map(async (file) => [file, await readFile(path.join(dist, file), "utf8")]),
		),
	);
	const sourceMaps = Object.fromEntries(
		await Promise.all(
			[
				"index.js.map",
				"conversation.js.map",
				"format.js.map",
				"theme.js.map",
				"theme-toggle.js.map",
				"testing.js.map",
				"styles.css.map",
			].map(async (file) => [file, JSON.parse(await readFile(path.join(dist, file), "utf8"))]),
		),
	);
	const buildErrors = validateBuildOutput({
		manifest,
		javascript: Object.values(distFiles),
		clientJavascript: {
			"index.js": distFiles["index.js"],
			"theme-toggle.js": distFiles["theme-toggle.js"],
		},
		sourceMaps,
		css: await readFile(path.join(dist, "styles.css"), "utf8"),
	});
	if (buildErrors.length > 0) throw new Error(buildErrors.join("\n"));
	await writeFile(path.join(STAGE, "package.json"), `${JSON.stringify(manifest, null, "\t")}\n`);
	return manifest;
}

async function packInto(destination) {
	await mkdir(destination, { recursive: true });
	await runPnpm(["pack", "--pack-destination", destination], { cwd: STAGE });
}

async function tarFiles(tarball) {
	const { stdout } = await exec("tar", ["-tzf", tarball], {
		maxBuffer: 10 * 1024 * 1024,
	});
	return stdout
		.split("\n")
		.map((line) => line.trim().replace(/\/$/, ""))
		.filter(Boolean)
		.sort();
}

function fixtureFiles(tarballName) {
	const testingEntry = "@fairchild/folio" + "/testing";
	const conversationEntry = "@fairchild/folio" + "/conversation";
	return {
		"package.json": `${JSON.stringify(
			{
				name: "folio-clean-consumer",
				version: "0.0.0",
				private: true,
				type: "module",
				scripts: { build: "next build" },
				dependencies: {
					"@fairchild/folio": `file:./${tarballName}`,
					ai: "7.0.15",
					next: "15.5.20",
					react: "19.2.7",
					"react-dom": "19.2.7",
				},
				devDependencies: {
					"@types/node": "22.20.0",
					"@types/react": "19.2.17",
					"@types/react-dom": "19.2.3",
					typescript: "5.9.3",
				},
			},
			null,
			"\t",
		)}\n`,
		"tsconfig.json": `${JSON.stringify(
			{
				compilerOptions: {
					target: "ES2022",
					lib: ["dom", "dom.iterable", "esnext"],
					strict: true,
					noEmit: true,
					module: "esnext",
					moduleResolution: "bundler",
					jsx: "preserve",
					plugins: [{ name: "next" }],
				},
				include: ["**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
			},
			null,
			"\t",
		)}\n`,
		"app/layout.tsx": `import type { ReactNode } from "react";\nimport { themeInitScript } from "@fairchild/folio/theme";\nimport "@fairchild/folio/styles.css";\nexport default function Layout({ children }: { children: ReactNode }) {\n  return <html lang="en" data-theme="light"><body><script dangerouslySetInnerHTML={{ __html: themeInitScript }} />{children}</body></html>;\n}\n`,
		"app/theme-control.tsx": `"use client";\nimport { ThemeToggle } from "@fairchild/folio/theme-toggle";\nexport function ThemeControl() { return <ThemeToggle />; }\n`,
		"app/page.tsx": `import { SessionView } from "@fairchild/folio";\nimport { ThemeControl } from "./theme-control";\nexport default function Page() {\n  return <><ThemeControl /><SessionView session={{ masthead: { repo: "fixture/repo", branch: "main", title: "Installed Folio", agentName: "Agent", stateLabel: "ready" }, messages: [], statusLine: { model: "fixture" }, empty: { title: "Clean install.", hint: "No workspace source." } }} /></>;\n}\n`,
		"app/api/format/route.ts": `import { formatTokenCount } from "@fairchild/folio/format";\nexport function GET() { return Response.json({ value: formatTokenCount(1200) }); }\n`,
		"app/api/testing/route.ts": `import { FolioUnknownCursorError as PublicError } from "${conversationEntry}";\nimport { FakeConversationPort, FolioUnknownCursorError as TestingError } from "${testingEntry}";\nexport function GET() { return Response.json({ fake: typeof FakeConversationPort, sameError: PublicError === TestingError }); }\n`,
		"contract.ts": `import { type FolioConversationPort } from "@fairchild/folio";\nimport { FakeConversationPort, FolioUnknownCursorError } from "${testingEntry}";\nexport const contract = { FakeConversationPort, FolioUnknownCursorError } satisfies Record<string, unknown>;\nexport type HostPort = FolioConversationPort;\n`,
	};
}

async function verifyCleanConsumer(tarball) {
	const fixture = await mkdtemp(path.join(os.tmpdir(), "folio-clean-consumer-"));
	try {
		const fixtureRoot = await realpath(fixture);
		const localTarball = path.join(fixture, path.basename(tarball));
		await cp(tarball, localTarball);
		for (const [relative, contents] of Object.entries(fixtureFiles(path.basename(tarball)))) {
			const target = path.join(fixture, relative);
			await mkdir(path.dirname(target), { recursive: true });
			await writeFile(target, contents);
		}
		const install = await runPnpm(["install", "--prefer-offline", "--ignore-workspace"], {
			cwd: fixture,
		});
		const installed = await realpath(path.join(fixture, "node_modules", "@fairchild", "folio"));
		if (!installed.startsWith(fixtureRoot + path.sep)) {
			throw new Error(`clean fixture resolved Folio outside itself: ${installed}`);
		}
		const identity = await exec(
			process.execPath,
			[
				"--input-type=module",
				"--eval",
				`import { FolioUnknownCursorError as PublicError } from "${"@fairchild/folio" + "/conversation"}"; import { FolioUnknownCursorError as TestingError } from "${"@fairchild/folio" + "/testing"}"; if (PublicError !== TestingError) throw new Error("entry identity mismatch");`,
			],
			{ cwd: fixture },
		);
		const build = await runPnpm(["--ignore-workspace", "run", "build"], {
			cwd: fixture,
			env: { NODE_ENV: "production", NEXT_TELEMETRY_DISABLED: "1" },
		});
		await writeFile(
			path.join(ARTIFACTS, "clean-fixture.log"),
			`INSTALL\n${install.stdout}${install.stderr}\nIDENTITY\n${identity.stdout}${identity.stderr}shared conversation runtime identity verified\nBUILD\n${build.stdout}${build.stderr}`,
		);
	} finally {
		await rm(fixture, { recursive: true, force: true });
	}
}

const manifest = await stagePackage();
const filename = tarballFilename(manifest.name, manifest.version);
await packInto(RUN_A);
await packInto(RUN_B);
const first = path.join(RUN_A, filename);
const second = path.join(RUN_B, filename);
const [firstSha256, secondSha256, files, packedStat] = await Promise.all([
	sha256(first),
	sha256(second),
	tarFiles(first),
	stat(first),
]);
const errors = validatePackedArtifact({
	manifest,
	files,
	packedBytes: packedStat.size,
	firstSha256,
	secondSha256,
});
if (errors.length > 0) throw new Error(errors.join("\n"));

const finalTarball = path.join(ARTIFACTS, filename);
await cp(first, finalTarball);
await writeFile(path.join(ARTIFACTS, "files.txt"), `${files.join("\n")}\n`);
await writeFile(
	path.join(ARTIFACTS, "manifest.json"),
	`${JSON.stringify(
		{
			name: manifest.name,
			version: manifest.version,
			filename,
			sha256: firstSha256,
			packedBytes: packedStat.size,
			files,
		},
		null,
		"\t",
	)}\n`,
);
await verifyCleanConsumer(finalTarball);

console.log(`packed ${path.relative(WEB_NEXT, finalTarball)}`);
console.log(`sha256 ${firstSha256}`);
console.log(`${packedStat.size} bytes, ${files.length} intentional files`);
console.log("clean standalone Next fixture installed without a workspace link and built successfully");
