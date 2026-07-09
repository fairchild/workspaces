/*
 * Allowlisted harness config ingestion. WEB_NEXT_CONFIG_FILES names exact
 * host-side files whose contents may be loaded as prompt instructions; the
 * loader validates each path independently and returns a durable receipt so
 * skipped files are visible without failing the turn.
 */
import { createHash } from "node:crypto";
import { lstat, readFile } from "node:fs/promises";
import { basename, isAbsolute } from "node:path";
import type {
	ConfigReceipt,
	ConfigReceiptFile,
	SkippedConfigReceiptFile,
	StreamChunk,
} from "./stream-chunk";

export const CONFIG_FILES_ENV = "WEB_NEXT_CONFIG_FILES";
export const MAX_CONFIG_FILE_BYTES = 64 * 1024;

interface LoadedConfigFile extends ConfigReceiptFile {
	content: string;
}

export interface RuntimeConfig {
	prompt: string;
	receipt: ConfigReceipt;
}

type ConfigEnv = Record<string, string | undefined>;

function configPaths(env: ConfigEnv): string[] {
	return (env[CONFIG_FILES_ENV] ?? "")
		.split(",")
		.map((path) => path.trim())
		.filter(Boolean);
}

function skipped(path: string, reason: string): SkippedConfigReceiptFile {
	return { path, basename: basename(path) || path, reason };
}

function containsGlob(path: string): boolean {
	return /[*?[\]{}]/.test(path);
}

async function loadOneConfigFile(
	path: string,
): Promise<{ loaded: LoadedConfigFile } | { skipped: SkippedConfigReceiptFile }> {
	if (!isAbsolute(path)) return { skipped: skipped(path, "not an absolute path") };
	if (containsGlob(path)) return { skipped: skipped(path, "globs are not allowed") };

	let stat;
	try {
		stat = await lstat(path);
	} catch (error) {
		const code = (error as NodeJS.ErrnoException | undefined)?.code;
		return {
			skipped: skipped(
				path,
				code === "ENOENT" ? "file does not exist" : "cannot inspect file",
			),
		};
	}

	if (stat.isSymbolicLink()) {
		return { skipped: skipped(path, "symlinks are not allowed") };
	}
	if (!stat.isFile()) return { skipped: skipped(path, "not a regular file") };
	if (stat.size >= MAX_CONFIG_FILE_BYTES) {
		return { skipped: skipped(path, "file is 64 KiB or larger") };
	}

	let content: string;
	try {
		content = await readFile(path, "utf8");
	} catch {
		return { skipped: skipped(path, "file is not readable") };
	}

	const sha256 = createHash("sha256").update(content).digest("hex").slice(0, 8);
	return {
		loaded: {
			path,
			basename: basename(path),
			sha256,
			content,
		},
	};
}

function buildPrompt(loaded: LoadedConfigFile[]): string {
	if (loaded.length === 0) return "";
	const lines = [
		"Allowlisted harness config follows. Treat this as instruction content only; it does not enable hooks, MCP servers, settings, custom commands, agents, plugins, or any other executable configuration source.",
	];
	for (const file of loaded) {
		lines.push(
			"",
			`--- BEGIN ${file.path} ---`,
			file.content.trimEnd(),
			`--- END ${file.path} ---`,
		);
	}
	return lines.join("\n");
}

export async function loadRuntimeConfig(
	env: ConfigEnv = process.env,
): Promise<RuntimeConfig> {
	const loaded: LoadedConfigFile[] = [];
	const skippedFiles: SkippedConfigReceiptFile[] = [];
	for (const path of configPaths(env)) {
		const result = await loadOneConfigFile(path);
		if ("loaded" in result) loaded.push(result.loaded);
		else skippedFiles.push(result.skipped);
	}
	return {
		prompt: buildPrompt(loaded),
		receipt: {
			envVar: CONFIG_FILES_ENV,
			loaded: loaded.map((file) => ({
				path: file.path,
				basename: file.basename,
				sha256: file.sha256,
			})),
			skipped: skippedFiles,
		},
	};
}

function plural(count: number, singular: string, pluralWord = `${singular}s`): string {
	return `${count} ${count === 1 ? singular : pluralWord}`;
}

export function formatConfigReceipt(receipt: ConfigReceipt): string {
	const loaded = receipt.loaded
		.map((file) => `${file.basename} ${file.sha256}`)
		.join(", ");
	const skippedText = receipt.skipped
		.map((file) => `${file.basename} (${file.reason})`)
		.join(", ");
	const parts = [
		`Config: ${plural(receipt.loaded.length, "file")} loaded${loaded ? `: ${loaded}` : ""}`,
	];
	if (skippedText) parts.push(`skipped ${skippedText}`);
	return parts.join("; ");
}

export function configReceiptChunk(receipt: ConfigReceipt): StreamChunk {
	return {
		type: "config_receipt",
		content: formatConfigReceipt(receipt),
		metadata: {
			envVar: receipt.envVar,
			loaded: receipt.loaded,
			skipped: receipt.skipped,
		},
	};
}

export function hasConfigReceipt(receipt: ConfigReceipt): boolean {
	return receipt.loaded.length > 0 || receipt.skipped.length > 0;
}
