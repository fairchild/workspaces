import { test as base, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

export type AxeFixtures = {
	axe: (options?: {
		include?: string[];
		exclude?: string[];
		disableRules?: string[];
	}) => Promise<{
		violations: Awaited<ReturnType<AxeBuilder["analyze"]>>["violations"];
		critical: number;
		serious: number;
	}>;
};

export const test = base.extend<AxeFixtures>({
	axe: async ({ page }, use) => {
		await use(async (options = {}) => {
			let builder = new AxeBuilder({ page });
			if (options.include) builder = builder.include(options.include);
			if (options.exclude) builder = builder.exclude(options.exclude);
			if (options.disableRules) builder = builder.disableRules(options.disableRules);
			const result = await builder.analyze();
			const critical = result.violations.filter((v) => v.impact === "critical").length;
			const serious = result.violations.filter((v) => v.impact === "serious").length;
			return { violations: result.violations, critical, serious };
		});
	},
});

export { expect };
