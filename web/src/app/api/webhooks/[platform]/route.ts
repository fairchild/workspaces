// TODO: re-enable chat bot integration in next PR
export async function POST(
	request: Request,
	{ params }: { params: Promise<{ platform: string }> },
): Promise<Response> {
	const { platform } = await params;
	return new Response(`webhook handler for ${platform} not yet configured`, {
		status: 501,
	});
}

export async function GET(
	_request: Request,
	{ params }: { params: Promise<{ platform: string }> },
): Promise<Response> {
	const { platform } = await params;
	return new Response(`webhook handler for ${platform} not yet configured`, {
		status: 501,
	});
}
