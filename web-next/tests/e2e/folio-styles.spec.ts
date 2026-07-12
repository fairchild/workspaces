/* Browser contract for Folio's package-owned, instance-scoped stylesheet. */
import { expect, test } from "@playwright/test";

test("package-only selectors apply inside a Folio root and nowhere else", async ({ page }) => {
	await page.goto("/sessions/demo");
	await expect(page.locator('[data-folio-root="surface"]')).toHaveCount(1);

	const animations = await page.evaluate(() => {
		const root = document.querySelector<HTMLElement>('[data-folio-root="surface"]');
		if (!root) throw new Error("missing Folio root");
		const inside = document.createElement("div");
		inside.className = "reasoning-content";
		inside.dataset.state = "open";
		root.append(inside);
		const outside = inside.cloneNode() as HTMLElement;
		document.body.append(outside);
		const result = {
			inside: getComputedStyle(inside).animationName,
			outside: getComputedStyle(outside).animationName,
		};
		inside.remove();
		outside.remove();
		return result;
	});

	expect(animations.inside).toBe("folio-reasoning-expand");
	expect(animations.outside).not.toBe("folio-reasoning-expand");
});

test("host utilities can override Folio's low-priority element defaults", async ({
	page,
}) => {
	await page.goto("/sessions/demo");

	const fontSize = await page.evaluate(() => {
		const root = document.querySelector<HTMLElement>('[data-folio-root="surface"]');
		if (!root) throw new Error("missing Folio root");
		const code = document.createElement("code");
		// text-3xl belongs to the Workspaces host source, not Folio's @source graph.
		code.className = "text-3xl";
		root.append(code);
		const result = getComputedStyle(code).fontSize;
		code.remove();
		return result;
	});

	expect(fontSize).toBe("30px");
});

test("token overrides stay local to each Folio instance", async ({ page }) => {
	await page.goto("/sessions/demo");

	const probes = await page.evaluate(() => {
		const makeProbe = (accent: string) => {
			const root = document.createElement("div");
			root.dataset.folioRoot = "surface";
			root.style.setProperty("--folio-accent", accent);
			const text = document.createElement("span");
			text.className = "text-accent text-tool";
			text.textContent = "probe";
			root.append(text);
			document.body.append(root);
			return { root, text };
		};
		const first = makeProbe("rgb(1, 2, 3)");
		const second = makeProbe("rgb(4, 5, 6)");
		const outside = document.createElement("span");
		outside.className = "text-tool";
		document.body.append(outside);
		const result = {
			firstColor: getComputedStyle(first.text).color,
			secondColor: getComputedStyle(second.text).color,
			insideSize: getComputedStyle(first.text).fontSize,
			outsideSize: getComputedStyle(outside).fontSize,
		};
		first.root.remove();
		second.root.remove();
		outside.remove();
		return result;
	});

	expect(probes.firstColor).toBe("rgb(1, 2, 3)");
	expect(probes.secondColor).toBe("rgb(4, 5, 6)");
	expect(probes.insideSize).toBe("13px");
	expect(probes.outsideSize).not.toBe("13px");
});

test("an explicit instance theme overrides its host and reaches root utilities", async ({
	page,
}) => {
	await page.goto("/sessions/demo");

	const themes = await page.evaluate(() => {
		document.documentElement.dataset.theme = "dark";
		const lightRoot = document.createElement("div");
		lightRoot.dataset.folioRoot = "surface";
		lightRoot.dataset.theme = "light";
		const lightText = document.createElement("span");
		lightText.className = "text-accent";
		lightRoot.append(lightText);
		document.body.append(lightRoot);

		const darkRoot = document.createElement("div");
		darkRoot.dataset.folioRoot = "surface";
		darkRoot.dataset.theme = "dark";
		darkRoot.className = "dark:rotate-180";
		document.body.append(darkRoot);

		const result = {
			lightAccent: getComputedStyle(lightText).color,
			darkRootRotation: getComputedStyle(darkRoot).rotate,
		};
		lightRoot.remove();
		darkRoot.remove();
		return result;
	});

	expect(themes.lightAccent).toBe("rgb(161, 92, 49)");
	expect(themes.darkRootRotation).toBe("180deg");
});
