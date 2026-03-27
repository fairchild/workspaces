import { getBot } from "@/lib/bot";
import { after } from "next/server";

export const dynamic = "force-dynamic";

/** Map URL slugs to Chat SDK adapter keys when they differ. */
const SLUG_MAP: Record<string, string> = {
	"github-bot": "github",
};

function resolveAdapter(slug: string): string {
	return SLUG_MAP[slug] ?? slug;
}

export async function POST(
	request: Request,
	{ params }: { params: Promise<{ platform: string }> },
): Promise<Response> {
	const { platform } = await params;
	const adapterKey = resolveAdapter(platform);
	const bot = getBot();
	const handler = bot.webhooks[adapterKey as keyof typeof bot.webhooks];
	if (!handler) {
		return new Response(`unknown platform: ${platform}`, { status: 404 });
	}
	return handler(request, { waitUntil: (p) => after(() => p) });
}

export async function GET(
	request: Request,
	{ params }: { params: Promise<{ platform: string }> },
): Promise<Response> {
	const { platform } = await params;
	const adapterKey = resolveAdapter(platform);
	const bot = getBot();
	const handler = bot.webhooks[adapterKey as keyof typeof bot.webhooks];
	if (!handler) {
		return new Response(`unknown platform: ${platform}`, { status: 404 });
	}
	return handler(request, { waitUntil: (p) => after(() => p) });
}
