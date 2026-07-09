import {
	chmodSync,
	mkdirSync,
	mkdtempSync,
	rmSync,
	symlinkSync,
	writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";
import {
	CONFIG_FILES_ENV,
	formatConfigReceipt,
	loadRuntimeConfig,
	MAX_CONFIG_FILE_BYTES,
	MAX_CONFIG_TOTAL_BYTES,
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
		const injectedContent = "Global instruction";
		writeFileSync(file, `${injectedContent}\n\n`);
		const expectedSha = createHash("sha256")
			.update(injectedContent)
			.digest("hex")
			.slice(0, 8);

		const config = await loadRuntimeConfig({ [CONFIG_FILES_ENV]: file });

		expect(config.prompt).toContain(`--- BEGIN ${file} ---`);
		expect(config.prompt).toContain(`--- BEGIN ${file} ---\n${injectedContent}\n--- END`);
		expect(config.prompt).toContain("instruction content only");
		expect(config.receipt.loaded).toEqual([
			{
				path: file,
				basename: "CLAUDE.md",
				sha256: expectedSha,
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

	test("warns when a symlink appears at open time", async () => {
		vi.resetModules();
		vi.doMock("node:fs/promises", () => ({
			lstat: vi.fn(async () => ({
				isSymbolicLink: () => false,
				isFile: () => true,
				size: 12,
			})),
			open: vi.fn(async () => {
				const error = new Error("symlink race") as NodeJS.ErrnoException;
				error.code = "ELOOP";
				throw error;
			}),
		}));

		try {
			const configFiles = await import("./config-files");
			const file = join(tempDir(), "race.md");

			const config = await configFiles.loadRuntimeConfig({
				[configFiles.CONFIG_FILES_ENV]: file,
			});

			expect(config.prompt).toBe("");
			expect(config.receipt.loaded).toEqual([]);
			expect(config.receipt.skipped).toEqual([
				expect.objectContaining({
					path: file,
					reason: "symlinks are not allowed",
				}),
			]);
		} finally {
			vi.doUnmock("node:fs/promises");
			vi.resetModules();
		}
	});

	test("skips files beyond the aggregate config budget", async () => {
		const dir = tempDir();
		const firstFiles = Array.from({ length: 4 }, (_, index) =>
			join(dir, `config-${index}.md`),
		);
		const overBudget = join(dir, "config-over-budget.md");
		for (const file of firstFiles) writeFileSync(file, "x".repeat(60 * 1024));
		writeFileSync(overBudget, "x".repeat(20 * 1024));

		const config = await loadRuntimeConfig({
			[CONFIG_FILES_ENV]: [...firstFiles, overBudget].join(","),
		});

		expect(config.receipt.loaded.map((file) => file.path)).toEqual(firstFiles);
		expect(config.receipt.skipped).toEqual([
			expect.objectContaining({
				path: overBudget,
				reason: "config budget exceeded",
			}),
		]);
		const loadedBytes = config.receipt.loaded.length * 60 * 1024;
		expect(loadedBytes).toBeLessThanOrEqual(MAX_CONFIG_TOTAL_BYTES);
		expect(loadedBytes + 20 * 1024).toBeGreaterThan(MAX_CONFIG_TOTAL_BYTES);
	});
});
