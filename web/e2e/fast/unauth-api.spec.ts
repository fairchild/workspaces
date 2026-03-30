import { expect, test } from "@playwright/test";

test.describe("Unauthenticated API responses @fast", () => {
	test("POST /api/workspaces/sync without auth returns unauthorized", async ({
		request,
	}) => {
		const res = await request.post("/api/workspaces/sync", {
			data: { workspaces: [] },
		});
		expect(res.status()).toBe(401);
		expect(await res.json()).toEqual({ error: "unauthorized" });
	});
});
