import {
	chmodSync,
	mkdirSync,
	mkdtempSync,
	rmSync,
	symlinkSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import {
	CONFIG_FILES_ENV,
	formatConfigReceipt,
	loadRuntimeConfig,
	MAX_CONFIG_FILE_BYTES,
} from "./config-files";

let dirs: string[] = [];

function tempDir(): string {
	const dir = mkdtempSync(join(tmpdir(), "web-next-config-files-"));
	dirs.push(dir);
	return dir;
}

afterEach(() => {
	for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
	dirs = [];
});

describe("loadRuntimeConfig", () => {
	test("defaults to no prompt and no receipt entries", async () => {
		const config = await loadRuntimeConfig({});

		expect(config.prompt).toBe("");
		expect(config.receipt).toEqual({
			envVar: CONFIG_FILES_ENV,
			loaded: [],
			skipped: [],
		});
	});

	test("loads allowlisted files as content with basename and sha receipt", async () => {
		const dir = tempDir();
		const file = join(dir, "CLAUDE.md");
		writeFileSync(file, "Global instruction\n");

		const config = await loadRuntimeConfig({ [CONFIG_FILES_ENV]: file });

		expect(config.prompt).toContain(`--- BEGIN ${file} ---`);
		expect(config.prompt).toContain("Global instruction");
		expect(config.prompt).toContain("instruction content only");
		expect(config.receipt.loaded).toEqual([
			{
				path: file,
				basename: "CLAUDE.md",
				sha256: expect.stringMatching(/^[a-f0-9]{8}$/),
			},
		]);
		expect(config.receipt.skipped).toEqual([]);
		expect(formatConfigReceipt(config.receipt)).toContain("CLAUDE.md");
	});

	test("warns per missing, symlink, oversize, and non-absolute file", async () => {
		const dir = tempDir();
		const target = join(dir, "target.md");
		const link = join(dir, "skill.md");
		const oversize = join(dir, "large.md");
		writeFileSync(target, "safe content");
		symlinkSync(target, link);
		writeFileSync(oversize, "x".repeat(MAX_CONFIG_FILE_BYTES));

		const config = await loadRuntimeConfig({
			[CONFIG_FILES_ENV]: [
				"relative.md",
				join(dir, "missing.md"),
				link,
				oversize,
			].join(","),
		});

		expect(config.prompt).toBe("");
		expect(config.receipt.loaded).toEqual([]);
		expect(config.receipt.skipped).toEqual([
			expect.objectContaining({
				path: "relative.md",
				reason: "not an absolute path",
			}),
			expect.objectContaining({
				path: join(dir, "missing.md"),
				reason: "file does not exist",
			}),
			expect.objectContaining({
				path: link,
				reason: "symlinks are not allowed",
			}),
			expect.objectContaining({
				path: oversize,
				reason: "file is 64 KiB or larger",
			}),
		]);
	});

	test("warns on directories, globs, and unreadable files without throwing", async () => {
		const dir = tempDir();
		const nested = join(dir, "folder");
		const unreadable = join(dir, "unreadable.md");
		mkdirSync(nested);
		writeFileSync(unreadable, "secret");
		chmodSync(unreadable, 0o000);

		try {
			const config = await loadRuntimeConfig({
				[CONFIG_FILES_ENV]: [nested, join(dir, "*.md"), unreadable].join(","),
			});

			expect(config.receipt.skipped).toEqual(
				expect.arrayContaining([
					expect.objectContaining({
						path: nested,
						reason: "not a regular file",
					}),
					expect.objectContaining({
						path: join(dir, "*.md"),
						reason: "globs are not allowed",
					}),
				]),
			);
		} finally {
			chmodSync(unreadable, 0o600);
		}
	});
});
