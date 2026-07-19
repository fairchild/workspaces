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
import { setTimeout as delay } from "node:timers/promises";
import { promisify } from "node:util";
import { gunzipSync } from "node:zlib";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
	createArtifactManifest,
	tarballFilename,
	validateAcceptedReleaseRecord,
	validateBuildOutput,
	validatePackedArtifact,
} from "./folio-artifact-core.mjs";

const exec = promisify(execFile);
const WEB_NEXT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const PACKAGE = path.join(WEB_NEXT, "packages", "folio");
const EXTERNAL_FIXTURE = path.join(WEB_NEXT, "fixtures", "external-consumer");
const ACCEPTED_RELEASE = path.join(EXTERNAL_FIXTURE, "accepted-release.json");
const ARTIFACTS = path.join(WEB_NEXT, "artifacts", "folio");
const STAGE_A = path.join(ARTIFACTS, "stage-a");
const STAGE_B = path.join(ARTIFACTS, "stage-b");
const RUN_A = path.join(ARTIFACTS, "pack-a");
const RUN_B = path.join(ARTIFACTS, "pack-b");
const CANONICAL_GIT_REMOTE = "https://github.com/fairchild/workspaces.git";
const RELEASE_BASE_URL = "https://github.com/fairchild/workspaces/releases/download";
const PNPM = process.env.npm_execpath;
const candidateMode = process.argv.includes("--candidate");

if (!PNPM) throw new Error("run this script through pnpm so npm_execpath is defined");
if (candidateMode && process.env.CI) {
	throw new Error("Folio candidate packaging is operator-only and cannot run in CI");
}

async function withRetry(label, operation) {
	let lastError;
	for (let attempt = 1; attempt <= 2; attempt += 1) {
		try {
			return await operation();
		} catch (error) {
			lastError = error;
			if (attempt < 2) await delay(500);
		}
	}
	throw new Error(`${label} failed after two attempts`, { cause: lastError });
}

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

function bufferSha256(buffer) {
	return createHash("sha256").update(buffer).digest("hex");
}

async function verifyAcceptedRelease(tarball, manifest, filename) {
	const accepted = JSON.parse(await readFile(ACCEPTED_RELEASE, "utf8"));
	const recordErrors = validateAcceptedReleaseRecord(accepted, manifest);
	if (recordErrors.length > 0) throw new Error(recordErrors.join("\n"));

	const repo = path.resolve(WEB_NEXT, "..");
	const { stdout: remoteTags } = await withRetry("canonical Folio tag lookup", () =>
		exec(
			"git",
			[
				"ls-remote",
				"--tags",
				CANONICAL_GIT_REMOTE,
				`refs/tags/${accepted.release}`,
				`refs/tags/${accepted.release}^{}`,
			],
			{ cwd: repo, timeout: 20_000 },
		),
	);
	const remoteCommit = remoteTags
		.trim()
		.split("\n")
		.filter(Boolean)
		.find((line) => line.endsWith("^{}"))
		?.split(/\s+/)[0] ?? remoteTags.trim().split(/\s+/)[0];
	if (remoteCommit !== accepted.sourceCommit) {
		throw new Error(
			`accepted release ${accepted.release} resolves to ${remoteCommit || "no remote tag"}, not ${accepted.sourceCommit}`,
		);
	}

	const localPayloadSha256 = bufferSha256(gunzipSync(await readFile(tarball)));
	if (localPayloadSha256 !== accepted.tarPayloadSha256) {
		throw new Error(
			`Folio ${manifest.version} tar payload ${localPayloadSha256} differs from accepted release ${accepted.tarPayloadSha256}; check source changes and pack-toolchain drift (accepted Node ${accepted.packToolchain.nodeMajor}, pnpm ${accepted.packToolchain.pnpmMajor}; current ${process.version}, ${process.env.npm_config_user_agent ?? "unknown pnpm"})`,
		);
	}

	const releaseUrl = `${RELEASE_BASE_URL}/${encodeURIComponent(accepted.release)}/${encodeURIComponent(filename)}`;
	const canonicalBytes = await withRetry("accepted Folio asset download", async () => {
		const result = await fetch(releaseUrl, {
			redirect: "follow",
			signal: AbortSignal.timeout(20_000),
		});
		if (!result.ok) {
			throw new Error(`HTTP ${result.status} ${result.statusText}`);
		}
		return Buffer.from(await result.arrayBuffer());
	});
	const canonicalCompressedSha256 = bufferSha256(canonicalBytes);
	if (canonicalCompressedSha256 !== accepted.compressedSha256) {
		throw new Error(
			`accepted release asset checksum ${canonicalCompressedSha256} differs from ${accepted.compressedSha256}`,
		);
	}
	const canonicalPayloadSha256 = bufferSha256(gunzipSync(canonicalBytes));
	if (canonicalPayloadSha256 !== accepted.tarPayloadSha256) {
		throw new Error(
			`accepted release asset payload ${canonicalPayloadSha256} differs from ${accepted.tarPayloadSha256}`,
		);
	}
	const canonicalTarball = path.join(ARTIFACTS, `accepted-${filename}`);
	await writeFile(canonicalTarball, canonicalBytes);
	return {
		...accepted,
		assetUrl: releaseUrl,
		canonicalTarball,
		localPayloadSha256,
	};
}

async function describeReleaseCandidate(tarball, manifest) {
	const accepted = JSON.parse(await readFile(ACCEPTED_RELEASE, "utf8"));
	if (accepted.packageVersion === manifest.version) {
		throw new Error(
			`Folio ${manifest.version} is already accepted; use the strict folio:package gate`,
		);
	}
	const repo = path.resolve(WEB_NEXT, "..");
	const { stdout: status } = await exec(
		"git",
		["status", "--porcelain", "--untracked-files=no"],
		{ cwd: repo },
	);
	if (status.trim()) {
		throw new Error("commit the Folio candidate before packaging so its source SHA is stable");
	}
	const { stdout: sourceCommit } = await exec("git", ["rev-parse", "HEAD"], {
		cwd: repo,
	});
	return {
		candidate: true,
		packageVersion: manifest.version,
		sourceCommit: sourceCommit.trim(),
		compressedSha256: await sha256(tarball),
		tarPayloadSha256: bufferSha256(gunzipSync(await readFile(tarball))),
		canonicalTarball: tarball,
	};
}

async function stagePackage(destination) {
	await runPnpm(["--filter", "@fairchild/folio", "build"]);
	await mkdir(destination, { recursive: true });
	await cp(path.join(PACKAGE, "dist"), path.join(destination, "dist"), {
		recursive: true,
	});
	for (const file of ["README.md", "LICENSE", "CHANGELOG.md"]) {
		await cp(path.join(PACKAGE, file), path.join(destination, file));
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
	await writeFile(path.join(destination, "package.json"), `${JSON.stringify(manifest, null, "\t")}\n`);
	return manifest;
}

async function packInto(source, destination) {
	await mkdir(destination, { recursive: true });
	await runPnpm(["pack", "--pack-destination", destination], { cwd: source });
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
				scripts: {
					build: "next build",
					test: "node --test test/*.test.mjs",
				},
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

async function verifyCleanConsumer(tarball, provenance) {
	const fixture = await mkdtemp(path.join(os.tmpdir(), "folio-clean-consumer-"));
	const log = [`PROVENANCE\n${provenance}`];
	let stage = "install";
	try {
		const fixtureRoot = await realpath(fixture);
		const localTarball = path.join(fixture, path.basename(tarball));
		await cp(tarball, localTarball);
		for (const [relative, contents] of Object.entries(fixtureFiles(path.basename(tarball)))) {
			const target = path.join(fixture, relative);
			await mkdir(path.dirname(target), { recursive: true });
			await writeFile(target, contents);
		}
		await mkdir(path.join(fixture, "test"), { recursive: true });
		for (const file of ["host-adapter.mjs", "contract.test.mjs"]) {
			await cp(path.join(EXTERNAL_FIXTURE, file), path.join(fixture, "test", file));
		}
		const install = await runPnpm(["install", "--prefer-offline", "--ignore-workspace"], {
			cwd: fixture,
		});
		log.push(`INSTALL\n${install.stdout}${install.stderr}`);
		stage = "isolation";
		const installed = await realpath(path.join(fixture, "node_modules", "@fairchild", "folio"));
		if (!installed.startsWith(fixtureRoot + path.sep)) {
			throw new Error(`clean fixture resolved Folio outside itself: ${installed}`);
		}
		log.push(`ISOLATION\ninstalled package resolved inside ${fixtureRoot}`);
		stage = "identity";
		const identity = await exec(
			process.execPath,
			[
				"--input-type=module",
				"--eval",
				`import { FolioUnknownCursorError as PublicError } from "${"@fairchild/folio" + "/conversation"}"; import { FolioUnknownCursorError as TestingError } from "${"@fairchild/folio" + "/testing"}"; if (PublicError !== TestingError) throw new Error("entry identity mismatch");`,
			],
			{ cwd: fixture },
		);
		log.push(
			`IDENTITY\n${identity.stdout}${identity.stderr}shared conversation runtime identity verified`,
		);
		stage = "external contract";
		const contract = await runPnpm(["--ignore-workspace", "test"], {
			cwd: fixture,
		});
		log.push(`EXTERNAL CONTRACT\n${contract.stdout}${contract.stderr}`);
		stage = "build";
		const build = await runPnpm(["--ignore-workspace", "run", "build"], {
			cwd: fixture,
			env: { NODE_ENV: "production", NEXT_TELEMETRY_DISABLED: "1" },
		});
		log.push(`BUILD\n${build.stdout}${build.stderr}`);
		await writeFile(path.join(ARTIFACTS, "clean-fixture.log"), `${log.join("\n")}\n`);
	} catch (error) {
		const stdout = typeof error?.stdout === "string" ? error.stdout : "";
		const stderr = typeof error?.stderr === "string" ? error.stderr : "";
		log.push(
			`${stage.toUpperCase()} FAILED\n${stdout}${stderr}${error instanceof Error ? error.stack : String(error)}`,
		);
		await writeFile(path.join(ARTIFACTS, "clean-fixture.log"), `${log.join("\n")}\n`);
		throw error;
	} finally {
		await rm(fixture, { recursive: true, force: true });
	}
}

await runPnpm(["run", "clean", "folio-artifact"]);
const manifest = await stagePackage(STAGE_A);
const filename = tarballFilename(manifest.name, manifest.version);
await packInto(STAGE_A, RUN_A);
await stagePackage(STAGE_B);
await packInto(STAGE_B, RUN_B);
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
const releaseProof = candidateMode
	? await describeReleaseCandidate(finalTarball, manifest)
	: await verifyAcceptedRelease(finalTarball, manifest, filename);
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
			...(releaseProof.candidate
				? {
					candidateRelease: {
						packageVersion: releaseProof.packageVersion,
						sourceCommit: releaseProof.sourceCommit,
						compressedSha256: releaseProof.compressedSha256,
						tarPayloadSha256: releaseProof.tarPayloadSha256,
					},
				}
				: {
					acceptedRelease: {
						tag: releaseProof.release,
						sourceCommit: releaseProof.sourceCommit,
						assetUrl: releaseProof.assetUrl,
						compressedSha256: releaseProof.compressedSha256,
						tarPayloadSha256: releaseProof.tarPayloadSha256,
						packToolchain: releaseProof.packToolchain,
					},
				}),
		},
		null,
		"\t",
	)}\n`,
);
await verifyCleanConsumer(
	releaseProof.canonicalTarball,
	releaseProof.candidate
		? `UNACCEPTED CANDIDATE ${releaseProof.packageVersion} at ${releaseProof.sourceCommit}; local checks only`
		: `downloaded ${releaseProof.release} from its public release asset; tag, source commit, compressed checksum, and tar payload verified`,
);

console.log(`packed ${path.relative(WEB_NEXT, finalTarball)}`);
console.log(`sha256 ${firstSha256}`);
if (releaseProof.candidate) {
	console.log(
		`UNACCEPTED CANDIDATE ${releaseProof.packageVersion} at ${releaseProof.sourceCommit}`,
	);
	console.log(`candidate asset sha256 ${releaseProof.compressedSha256}`);
	console.log(`candidate tar payload sha256 ${releaseProof.tarPayloadSha256}`);
} else {
	console.log(
		`tar payload sha256 ${releaseProof.localPayloadSha256} matches ${releaseProof.release}`,
	);
	console.log(
		`accepted asset sha256 ${releaseProof.compressedSha256} downloaded and verified at source commit ${releaseProof.sourceCommit}`,
	);
}
console.log(`${packedStat.size} bytes, ${files.length} intentional files`);
console.log(
	releaseProof.candidate
		? "clean standalone Next fixture installed the local unaccepted candidate without a workspace link, passed the external-host contract, and built successfully"
		: "clean standalone Next fixture installed the canonical release asset without a workspace link, passed the external-host contract, and built successfully",
);
