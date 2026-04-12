"use client";

import { identifyPostHogUser } from "@/lib/posthog-browser";
import { useEffect } from "react";

type PostHogUserIdentifyProps = {
	id: string;
	email: string | null;
	name: string | null;
};

export function PostHogUserIdentify({
	id,
	email,
	name,
}: PostHogUserIdentifyProps) {
	useEffect(() => {
		identifyPostHogUser(id, {
			email: email ?? undefined,
			name: name ?? undefined,
		});
	}, [email, id, name]);

	return null;
}
