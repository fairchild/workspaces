import { describe, expect, test } from "vitest";
import sourceManifest from "../packages/folio/package.json";
import {
	ARTIFACT_EXPORTS,
	createArtifactManifest,
	MAX_PACKED_BYTES,
	PACKED_FILES,
	runtimeImports,
	tarballFilename,
	validateAcceptedReleaseRecord,
	validateBuildOutput,
	validatePackedArtifact,
} from "./folio-artifact-core.mjs";

describe("Folio artifact contract", () => {
	test("derives a private compiled manifest without workspace-only metadata", () => {
		const manifest = createArtifactManifest(sourceManifest);

		expect(manifest).toMatchObject({
			name: "@fairchild/folio",
			version: "0.1.0",
			private: true,
			types: "./dist/index.d.ts",
			module: "./dist/index.js",
			exports: ARTIFACT_EXPORTS,
			files: ["dist", "README.md", "LICENSE", "CHANGELOG.md"],
		});
		expect(manifest).not.toHaveProperty("scripts");
		expect(manifest).not.toHaveProperty("devDependencies");
	});

	test("pins the deterministic file allowlist, checksum, and size budget", () => {
		const manifest = createArtifactManifest(sourceManifest);
		expect(
			validatePackedArtifact({
				manifest,
				files: PACKED_FILES,
				packedBytes: MAX_PACKED_BYTES,
				firstSha256: "same",
				secondSha256: "same",
			}),
		).toEqual([]);

		expect(
			validatePackedArtifact({
				manifest,
				files: [...PACKED_FILES, "package/private.txt"],
				packedBytes: MAX_PACKED_BYTES + 1,
				firstSha256: "first",
				secondSha256: "second",
			}),
		).toEqual([
			"tarball file list differs from the intentional allowlist",
			`packed size ${MAX_PACKED_BYTES + 1} exceeds ${MAX_PACKED_BYTES} byte budget`,
			"two packs of the same staged package produced different checksums",
		]);
	});

	test("uses the stable scoped-package tarball name", () => {
		expect(tarballFilename("@fairchild/folio", "0.1.0")).toBe(
			"fairchild-folio-0.1.0.tgz",
		);
	});

	test("fails closed until package provenance has an accepted release record", () => {
		const manifest = createArtifactManifest(sourceManifest);
		const accepted = {
			release: "folio-v0.1.0",
			packageVersion: "0.1.0",
			sourceCommit: "a".repeat(40),
			compressedSha256: "b".repeat(64),
			tarPayloadSha256: "c".repeat(64),
		};

		expect(validateAcceptedReleaseRecord(accepted, manifest)).toEqual([]);
		expect(
			validateAcceptedReleaseRecord(
				{
					...accepted,
					release: "wrong-tag",
					packageVersion: "0.2.0",
					sourceCommit: "short",
					compressedSha256: "invalid",
					tarPayloadSha256: "invalid",
				},
				manifest,
			),
		).toEqual([
			"Folio 0.1.0 has no accepted release record (found 0.2.0)",
			"accepted release tag must match its package version",
			"accepted release source commit must be a full lowercase SHA-1",
			"accepted release compressedSha256 must be a full lowercase SHA-256",
			"accepted release tarPayloadSha256 must be a full lowercase SHA-256",
		]);
	});

	test("detects undeclared imports, uncompiled CSS, unpacked assets, and incomplete maps", () => {
		const manifest = createArtifactManifest(sourceManifest);
		expect(runtimeImports('import "react/jsx-runtime"; import x from "@scope/pkg/x";')).toEqual(
			["react", "@scope/pkg"],
		);
		expect(
			validateBuildOutput({
				manifest,
				javascript: ['import "react/jsx-runtime"; import "undeclared-package";'],
				sourceMaps: {
					"index.js.map": { sources: ["/checkout/src.ts"], sourcesContent: [] },
					"missing.js.map": {},
				},
				css: '@import "tailwindcss/theme"; @source "./src"; .icon { background: url("./missing.svg"); }',
			}),
		).toEqual([
			"undeclared runtime imports: undeclared-package",
			"compiled stylesheet still requires Tailwind source processing",
			"compiled stylesheet references unpacked assets: ./missing.svg",
			"index.js.map lacks complete source-map sourcesContent",
			"index.js.map contains checkout-specific absolute source paths",
			"missing.js.map lacks complete source-map sourcesContent",
		]);
	});

	test("rejects client bundles that lose their React boundary directive", () => {
		const manifest = createArtifactManifest(sourceManifest);
		expect(
			validateBuildOutput({
				manifest,
				javascript: [],
				clientJavascript: {
					"index.js": '"use client";\nexport const ok = true;',
					"theme-toggle.js": "export const missing = true;",
				},
				sourceMaps: {},
				css: "",
			}),
		).toEqual(["theme-toggle.js lost its use client boundary"]);
	});

	test("rejects duplicate conversation runtime identities in client entries", () => {
		const manifest = createArtifactManifest(sourceManifest);
		expect(
			validateBuildOutput({
				manifest,
				javascript: [],
				clientJavascript: {
					"index.js": '"use client";\nclass FolioUnknownCursorError {}',
				},
				sourceMaps: {},
				css: "",
			}),
		).toEqual(["index.js bundles conversation runtime identities"]);
	});
});
