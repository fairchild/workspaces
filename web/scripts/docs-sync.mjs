import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import {
	cp,
	mkdir,
	readFile,
	readdir,
	rm,
	stat,
	writeFile,
} from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(scriptDir, "..");
const repoRoot = path.resolve(webRoot, "..");
const publicDocsRoot = path.join(webRoot, "public", "docs");
const manifestPath = path.join(scriptDir, "docs-sync-manifest.json");
const readerTemplatePath = sourcePath("docs/reader.html");
const checkMode = process.argv.includes("--check");
const localMode = process.argv.includes("--local");

const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
const topicCatalog = manifest.topics ?? [];
const publicEntries = manifest.documents.map(normalizeManifestEntry);
const publicManifest = docsManifest(publicEntries, { local: false });

function sourcePath(relativePath) {
	return path.join(repoRoot, relativePath);
}

function destPath(relativePath) {
	return path.join(publicDocsRoot, relativePath);
}

function sortJson(value) {
	return `${JSON.stringify(value, null, "\t")}\n`;
}

function renderedRoute(markdownPath) {
	return markdownPath.replace(/\.md$/, "");
}

function renderedPagePath(markdownPath) {
	return path.join(renderedRoute(markdownPath), "index.html");
}

function sha256(content) {
	return createHash("sha256").update(content).digest("hex");
}

function normalizeManifestEntry({
	source,
	dest,
	title,
	group,
	topics,
	summary,
	type,
	published,
}) {
	return {
		source,
		dest,
		title,
		group,
		topics: topics ?? [],
		summary,
		type: type ?? group ?? "Docs",
		published: published ?? true,
	};
}

function docsManifest(entries, { local }) {
	return {
		generatedBy: "web/scripts/docs-sync.mjs",
		local,
		documents: entries.map((entry) => entry.dest),
		renderedRoutes: entries.map((entry) => renderedRoute(entry.dest)),
		entries: entries.map(
			({ source, dest, title, group, topics, summary, type, published }) => ({
				source,
				dest,
				title,
				group,
				topics,
				summary,
				type,
				published,
			}),
		),
		topics: topicCatalog,
	};
}

async function localDocsEntries() {
	const result = spawnSync(
		"python3",
		["scripts/docs_catalog.py", "local-manifest", "--repo-root", repoRoot],
		{ cwd: repoRoot, encoding: "utf8" },
	);
	if (result.error) throw result.error;
	if (result.status !== 0) {
		throw new Error(
			`local docs catalog failed:\n${result.stderr || result.stdout}`,
		);
	}
	return JSON.parse(result.stdout).entries;
}

async function readGeneratedFile(entry) {
	return await readFile(sourcePath(entry.source), "utf8");
}

async function readRenderedPage(markdownPath) {
	const template = await readFile(readerTemplatePath, "utf8");
	const config = `    window.WORKSPACES_DOC_PATH = ${JSON.stringify(markdownPath)};\n`;
	return template.replace(
		"    const docsBase =",
		`${config}    const docsBase =`,
	);
}

async function assertSourceExists(relativePath) {
	if (!existsSync(sourcePath(relativePath))) {
		throw new Error(`Missing docs source: ${relativePath}`);
	}
}

async function copyDirectory(
	source,
	destination,
	includeExtensions,
	excludeNames = [],
) {
	const sourceStats = await stat(source);
	if (!sourceStats.isDirectory()) {
		throw new Error(`Expected directory: ${path.relative(repoRoot, source)}`);
	}
	await mkdir(destination, { recursive: true });
	const entries = await readdir(source, { withFileTypes: true });
	for (const entry of entries) {
		const from = path.join(source, entry.name);
		const to = path.join(destination, entry.name);
		if (entry.isDirectory()) {
			await copyDirectory(from, to, includeExtensions);
			continue;
		}
		if (
			includeExtensions &&
			!includeExtensions.includes(path.extname(entry.name))
		) {
			continue;
		}
		if (excludeNames.includes(entry.name)) {
			continue;
		}
		await cp(from, to);
	}
}

async function syncDocs({ entries = publicEntries, local = false } = {}) {
	const generatedManifest = docsManifest(entries, { local });
	await rm(publicDocsRoot, { recursive: true, force: true });
	await mkdir(publicDocsRoot, { recursive: true });

	await mkdir(destPath("_renderer"), { recursive: true });
	await writeFile(
		destPath("_renderer/index.html"),
		await readRenderedPage(null),
	);

	for (const entry of manifest.staticFiles) {
		const content = await readGeneratedFile(entry);
		const target = destPath(entry.dest);
		await mkdir(path.dirname(target), { recursive: true });
		await writeFile(target, content);
	}

	if (local) {
		const indexSource = "docs/developer-operator-index.html";
		const indexTarget = destPath("developer-operator-index.html");
		await mkdir(path.dirname(indexTarget), { recursive: true });
		await writeFile(
			indexTarget,
			await readGeneratedFile({ source: indexSource }),
		);
	}

	for (const entry of entries) {
		const content = await readGeneratedFile(entry);
		const target = destPath(entry.dest);
		await mkdir(path.dirname(target), { recursive: true });
		await writeFile(target, content);

		const renderedTarget = destPath(renderedPagePath(entry.dest));
		await mkdir(path.dirname(renderedTarget), { recursive: true });
		await writeFile(renderedTarget, await readRenderedPage(entry.dest));
	}

	await writeFile(destPath("docs-manifest.json"), sortJson(publicManifest));
	if (local) {
		await writeFile(
			destPath("local-docs-manifest.json"),
			sortJson(generatedManifest),
		);
	}

	for (const entry of manifest.assetDirectories) {
		await copyDirectory(
			sourcePath(entry.source),
			destPath(entry.dest),
			entry.include,
			local ? [] : ["operator-index.css", "operator-index.js"],
		);
	}
}

async function compareFile(relativePath, expected) {
	const target = destPath(relativePath);
	if (!existsSync(target)) {
		return [`${relativePath} is missing`];
	}
	const actual = await readFile(target, "utf8");
	if (actual !== expected) {
		return [
			`${relativePath} is stale (${sha256(actual)} != ${sha256(expected)})`,
		];
	}
	return [];
}

async function collectFiles(directory) {
	const files = [];
	const entries = await readdir(directory, { withFileTypes: true });
	for (const entry of entries) {
		const fullPath = path.join(directory, entry.name);
		if (entry.isDirectory()) {
			files.push(...(await collectFiles(fullPath)));
			continue;
		}
		files.push(fullPath);
	}
	return files;
}

async function checkDirectory(
	source,
	destination,
	includeExtensions,
	excludeNames = [],
) {
	const errors = [];
	if (!existsSync(destination)) {
		return [`${path.relative(publicDocsRoot, destination)} is missing`];
	}
	const sourceFiles = await collectFiles(source);
	for (const file of sourceFiles) {
		if (includeExtensions && !includeExtensions.includes(path.extname(file))) {
			continue;
		}
		if (excludeNames.includes(path.basename(file))) {
			continue;
		}
		const relative = path.relative(source, file);
		const generated = path.join(destination, relative);
		if (!existsSync(generated)) {
			errors.push(`${path.relative(publicDocsRoot, generated)} is missing`);
			continue;
		}
		const [sourceBytes, generatedBytes] = await Promise.all([
			readFile(file),
			readFile(generated),
		]);
		if (!sourceBytes.equals(generatedBytes)) {
			errors.push(`${path.relative(publicDocsRoot, generated)} is stale`);
		}
	}
	return errors;
}

function extractLinks(content) {
	const links = [];
	const linkableContent = content
		.replace(/<script\b[\s\S]*?<\/script>/gi, "")
		.replace(/```[\s\S]*?```/g, "");
	for (const match of linkableContent.matchAll(/!?\[[^\]]*]\(([^)]+)\)/g)) {
		links.push(match[1].trim());
	}
	for (const match of linkableContent.matchAll(
		/\b(?:href|src)=["']([^"']+)["']/g,
	)) {
		links.push(match[1].trim());
	}
	return links;
}

function isExternalLink(link) {
	return /^(https?:|mailto:|data:|#)/.test(link);
}

function normalizePublicDocsLink(link) {
	if (!link.startsWith("/docs/")) return null;
	const parsed = new URL(link, "https://docs.local/docs/");
	let pathname = parsed.pathname;
	if (!pathname.startsWith("/docs/")) return null;
	pathname = decodeURIComponent(pathname.slice("/docs/".length));
	if (!pathname || pathname.includes("..")) return null;
	const extension = path.extname(pathname);
	if (extension && extension !== ".md") return null;
	if (pathname.endsWith(".md")) return pathname;
	if (pathname.endsWith("/")) pathname = pathname.slice(0, -1);
	return `${pathname}.md`;
}

function resolveSourceLink(link, fromSource) {
	const withoutHash = link.split("#")[0];
	if (!withoutHash) return null;
	if (withoutHash.startsWith("/")) return path.join(repoRoot, withoutHash);
	return path.resolve(path.dirname(sourcePath(fromSource)), withoutHash);
}

async function validateLinks() {
	const errors = [];
	const sourceEntries = [...manifest.staticFiles, ...manifest.documents];
	const publicDocs = new Set(publicManifest.documents);

	for (const entry of sourceEntries) {
		const content = await readGeneratedFile(entry);
		for (const link of extractLinks(content)) {
			if (isExternalLink(link)) continue;
			const publicDoc = normalizePublicDocsLink(link);
			if (publicDoc) {
				if (!publicDocs.has(publicDoc)) {
					errors.push(`${entry.source} links to unpublished doc: ${link}`);
				}
				continue;
			}
			const target = resolveSourceLink(link, entry.source);
			if (!target) continue;
			if (!target.startsWith(repoRoot)) {
				errors.push(`${entry.source} links outside repo: ${link}`);
				continue;
			}
			if (!existsSync(target)) {
				errors.push(`${entry.source} links to missing file: ${link}`);
			}
		}
	}

	return errors;
}

async function checkDocs() {
	const errors = [];
	for (const entry of [...manifest.staticFiles, ...manifest.documents]) {
		await assertSourceExists(entry.source);
		errors.push(
			...(await compareFile(entry.dest, await readGeneratedFile(entry))),
		);
	}

	await assertSourceExists("docs/reader.html");
	errors.push(
		...(await compareFile(
			"_renderer/index.html",
			await readRenderedPage(null),
		)),
	);
	for (const entry of manifest.documents) {
		errors.push(
			...(await compareFile(
				renderedPagePath(entry.dest),
				await readRenderedPage(entry.dest),
			)),
		);
	}

	errors.push(
		...(await compareFile("docs-manifest.json", sortJson(publicManifest))),
	);

	for (const entry of manifest.assetDirectories) {
		const source = sourcePath(entry.source);
		const destination = destPath(entry.dest);
		if (!existsSync(source)) {
			errors.push(`${entry.source} is missing`);
			continue;
		}
		errors.push(
			...(await checkDirectory(source, destination, entry.include, [
				"operator-index.css",
				"operator-index.js",
			])),
		);
	}

	errors.push(...(await validateLinks()));

	if (errors.length) {
		console.error("Docs sync check failed:");
		for (const error of errors) {
			console.error(`- ${error}`);
		}
		process.exitCode = 1;
		return;
	}

	console.log("Docs public assets are in sync.");
}

if (checkMode) {
	await checkDocs();
} else {
	const entries = localMode ? await localDocsEntries() : publicEntries;
	await syncDocs({ entries, local: localMode });
	console.log(
		`Synced ${entries.length} docs to web/public/docs${localMode ? " (local mode)" : ""}.`,
	);
}
