/* Pure manifest, file-list, and size contracts for Folio's install artifact. */

export const MAX_PACKED_BYTES = 120_000;

export const DIST_FILES = [
	"conversation.d.ts",
	"conversation.js",
	"conversation.js.map",
	"format.d.ts",
	"format.js",
	"format.js.map",
	"index.d.ts",
	"index.js",
	"index.js.map",
	"styles.css",
	"styles.css.map",
	"testing.d.ts",
	"testing.js",
	"testing.js.map",
	"theme-toggle.d.ts",
	"theme-toggle.js",
	"theme-toggle.js.map",
	"theme.d.ts",
	"theme.js",
	"theme.js.map",
];

export const PACKED_FILES = [
	"package/CHANGELOG.md",
	"package/LICENSE",
	"package/README.md",
	...DIST_FILES.map((file) => `package/dist/${file}`),
	"package/package.json",
].sort();

export const ARTIFACT_EXPORTS = {
	".": {
		types: "./dist/index.d.ts",
		import: "./dist/index.js",
		default: "./dist/index.js",
	},
	"./format": {
		types: "./dist/format.d.ts",
		import: "./dist/format.js",
		default: "./dist/format.js",
	},
	"./conversation": {
		types: "./dist/conversation.d.ts",
		import: "./dist/conversation.js",
		default: "./dist/conversation.js",
	},
	"./theme": {
		types: "./dist/theme.d.ts",
		import: "./dist/theme.js",
		default: "./dist/theme.js",
	},
	"./theme-toggle": {
		types: "./dist/theme-toggle.d.ts",
		import: "./dist/theme-toggle.js",
		default: "./dist/theme-toggle.js",
	},
	"./styles.css": "./dist/styles.css",
	"./testing": {
		types: "./dist/testing.d.ts",
		import: "./dist/testing.js",
		default: "./dist/testing.js",
	},
};

export function createArtifactManifest(source) {
	return {
		name: source.name,
		version: source.version,
		private: true,
		type: "module",
		description: source.description,
		types: "./dist/index.d.ts",
		module: "./dist/index.js",
		license: source.license,
		repository: source.repository,
		exports: ARTIFACT_EXPORTS,
		files: ["dist", "README.md", "LICENSE", "CHANGELOG.md"],
		sideEffects: ["./dist/styles.css"],
		folioCompatibility: source.folioCompatibility,
		peerDependencies: source.peerDependencies,
		dependencies: source.dependencies,
	};
}

export function tarballFilename(name, version) {
	return `${name.replace(/^@/, "").replaceAll("/", "-")}-${version}.tgz`;
}

export function validateAcceptedReleaseRecord(accepted, manifest) {
	const errors = [];
	if (accepted?.packageVersion !== manifest.version) {
		errors.push(
			`Folio ${manifest.version} has no accepted release record (found ${accepted?.packageVersion ?? "none"})`,
		);
	}
	if (accepted?.release !== `folio-v${accepted?.packageVersion}`) {
		errors.push("accepted release tag must match its package version");
	}
	if (!/^[0-9a-f]{40}$/.test(accepted?.sourceCommit ?? "")) {
		errors.push("accepted release source commit must be a full lowercase SHA-1");
	}
	for (const field of ["compressedSha256", "tarPayloadSha256"]) {
		if (!/^[0-9a-f]{64}$/.test(accepted?.[field] ?? "")) {
			errors.push(`accepted release ${field} must be a full lowercase SHA-256`);
		}
	}
	if (!Number.isInteger(accepted?.packToolchain?.nodeMajor)) {
		errors.push("accepted release packToolchain.nodeMajor must be an integer");
	}
	if (!Number.isInteger(accepted?.packToolchain?.pnpmMajor)) {
		errors.push("accepted release packToolchain.pnpmMajor must be an integer");
	}
	return errors;
}

function packageName(specifier) {
	if (specifier.startsWith("@")) return specifier.split("/").slice(0, 2).join("/");
	return specifier.split("/")[0];
}

export function runtimeImports(javascript) {
	const specifiers = [
		...javascript.matchAll(/(?:from\s+|import\s*(?:\(\s*)?)(["'])([^"']+)\1/g),
	].map((match) => match[2]);
	return [...new Set(specifiers.filter((value) => !value.startsWith(".")).map(packageName))];
}

export function validateBuildOutput({
	manifest,
	javascript,
	clientJavascript = {},
	sourceMaps,
	css,
}) {
	const errors = [];
	const declared = new Set([
		...Object.keys(manifest.dependencies ?? {}),
		...Object.keys(manifest.peerDependencies ?? {}),
	]);
	const imports = javascript.flatMap(runtimeImports);
	const undeclared = [...new Set(imports.filter((name) => !declared.has(name)))].sort();
	if (undeclared.length > 0) {
		errors.push(`undeclared runtime imports: ${undeclared.join(", ")}`);
	}
	if (/@source|@import\s+["']tailwindcss/.test(css)) {
		errors.push("compiled stylesheet still requires Tailwind source processing");
	}
	const unpackedAssets = [
		...css.matchAll(/url\(\s*(["']?)([^"')]+)\1\s*\)/g),
	]
		.map((match) => match[2].trim())
		.filter((url) => !url.startsWith("data:") && !url.startsWith("#"));
	if (unpackedAssets.length > 0) {
		errors.push(
			`compiled stylesheet references unpacked assets: ${[...new Set(unpackedAssets)].sort().join(", ")}`,
		);
	}
	for (const [name, source] of Object.entries(clientJavascript)) {
		if (!/^\s*["']use client["'];/.test(source)) {
			errors.push(`${name} lost its use client boundary`);
		}
		if (/Folio(?:UnknownCursor|CapabilityUnavailable)Error/.test(source)) {
			errors.push(`${name} bundles conversation runtime identities`);
		}
	}
	for (const [name, sourceMap] of Object.entries(sourceMaps)) {
		const sources = Array.isArray(sourceMap.sources) ? sourceMap.sources : [];
		if (
			sources.length === 0 ||
			!Array.isArray(sourceMap.sourcesContent) ||
			sourceMap.sourcesContent.length !== sources.length
		) {
			errors.push(`${name} lacks complete source-map sourcesContent`);
		}
		if (sources.some((source) => pathIsAbsolute(source))) {
			errors.push(`${name} contains checkout-specific absolute source paths`);
		}
	}
	return errors;
}

function pathIsAbsolute(value) {
	return value.startsWith("/") || /^[A-Za-z]:[\\/]/.test(value);
}

export function validatePackedArtifact({
	manifest,
	files,
	packedBytes,
	firstSha256,
	secondSha256,
}) {
	const errors = [];
	if (manifest.name !== "@fairchild/folio") errors.push("unexpected package name");
	if (!/^0\.\d+\.\d+$/.test(manifest.version)) {
		errors.push("version must be pre-1.0 semantic versioning");
	}
	if (manifest.private !== true) errors.push("registry publication gate must stay closed");
	if (JSON.stringify(manifest.exports) !== JSON.stringify(ARTIFACT_EXPORTS)) {
		errors.push("artifact exports differ from the public contract");
	}
	if (manifest.sideEffects?.length !== 1 || manifest.sideEffects[0] !== "./dist/styles.css") {
		errors.push("only the compiled stylesheet may be a package side effect");
	}
	if (JSON.stringify([...files].sort()) !== JSON.stringify(PACKED_FILES)) {
		errors.push("tarball file list differs from the intentional allowlist");
	}
	if (packedBytes > MAX_PACKED_BYTES) {
		errors.push(`packed size ${packedBytes} exceeds ${MAX_PACKED_BYTES} byte budget`);
	}
	if (firstSha256 !== secondSha256) {
		errors.push("two packs of the same staged package produced different checksums");
	}
	return errors;
}
