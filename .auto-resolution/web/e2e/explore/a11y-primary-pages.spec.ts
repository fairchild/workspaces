import { test, expect } from "./axe-fixture";

const PRIMARY_PAGES = [
	{ slug: "landing", url: "/" },
	{ slug: "dashboard", url: "/dashboard/fairchild/workspaces" },
];

for (const page of PRIMARY_PAGES) {
	test(`${page.slug}: zero axe-critical violations`, async ({ page: p, axe }) => {
		await p.goto(page.url);
		await p.waitForLoadState("networkidle");
		const { violations, critical } = await axe();
		if (violations.length > 0) {
			console.log(
				`[a11y] ${page.slug} violations:`,
				violations.map((v) => `${v.impact}/${v.id}`).join(", "),
			);
		}
		expect(critical, `critical a11y violations on ${page.slug}`).toBe(0);
	});
}
