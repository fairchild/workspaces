/*
 * Browser-side Better Auth client — the sign-in/out calls the sign-in page
 * and the access-denied page use in real OAuth mode.
 */
import { createAuthClient } from "better-auth/react";

export const { signIn, signOut } = createAuthClient();
