import { bot } from "@/lib/bot";
import { after } from "next/server";

export async function POST(
	request: Request,
	{ params }: { params: Promise<{ platform: string }> },
): Promise<Response> {
	const { platform } = await params;
	const webhookHandler = bot.webhooks[platform as keyof typeof bot.webhooks] as
		| ((
				req: Request,
				opts: { waitUntil: (task: Promise<unknown>) => void },
		  ) => Promise<Response>)
		| undefined;
	if (!webhookHandler) {
		return new Response(`Unknown platform: ${platform}`, { status: 404 });
	}
	return webhookHandler(request, {
		waitUntil: (task: Promise<unknown>) => after(() => task),
	});
}

export async function GET(
	request: Request,
	{ params }: { params: Promise<{ platform: string }> },
): Promise<Response> {
	const { platform } = await params;
	const webhookHandler = bot.webhooks[platform as keyof typeof bot.webhooks] as
		| ((
				req: Request,
				opts: { waitUntil: (task: Promise<unknown>) => void },
		  ) => Promise<Response>)
		| undefined;
	if (!webhookHandler) {
		return new Response(`Unknown platform: ${platform}`, { status: 404 });
	}
	return webhookHandler(request, {
		waitUntil: (task: Promise<unknown>) => after(() => task),
	});
}
