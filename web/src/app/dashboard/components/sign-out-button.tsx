"use client";

import { signOut } from "@/lib/auth-client";
import styles from "./sign-out-button.module.css";

export function SignOutButton() {
	return (
		<button
			type="button"
			className={styles.button}
			onClick={() =>
				signOut({
					fetchOptions: { onSuccess: () => window.location.assign("/") },
				})
			}
		>
			Sign out
		</button>
	);
}
