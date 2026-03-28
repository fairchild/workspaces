import type { Page } from "@playwright/test";
import { existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const EVIDENCE_DIR = join(process.cwd(), "e2e", "evidence");

export function evidencePath(name: string): string {
	if (!existsSync(EVIDENCE_DIR)) {
		mkdirSync(EVIDENCE_DIR, { recursive: true });
	}
	return join(EVIDENCE_DIR, name);
}

export async function screenshot(page: Page, name: string): Promise<string> {
	const path = evidencePath(`${name}.png`);
	await page.screenshot({ path, fullPage: true });
	return path;
}

export async function screenshotElement(
	page: Page,
	selector: string,
	name: string,
): Promise<string> {
	const path = evidencePath(`${name}.png`);
	await page.locator(selector).screenshot({ path });
	return path;
}
