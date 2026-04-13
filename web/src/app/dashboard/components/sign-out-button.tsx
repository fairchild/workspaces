"use client";

import { signOut } from "@/lib/auth-client";
import { resetPostHogUser } from "@/lib/posthog-browser";
import styles from "./sign-out-button.module.css";

export function SignOutButton() {
	return (
		<button
			type="button"
			className={styles.button}
			onClick={() =>
				signOut({
					fetchOptions: {
						onSuccess: () => {
							resetPostHogUser();
							window.location.assign("/");
						},
					},
				})
			}
		>
			Sign out
		</button>
	);
}
