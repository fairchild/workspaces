/*
 * The pairing-ack record under WEB_NEXT_DATA_DIR: one small 0600 file naming
 * when a device last redeemed a pairing and how (explicit handshake POST, or
 * a sign-in bounce). Shared by the handshake route and the sign-in
 * redemption bounce so both paths flip the desktop's pairing window.
 */
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { resolveWebNextDataDir } from "@/lib/local-data-dir";

const ACK_FILENAME = "pairing-ack.json";
const USER_AGENT_MAX = 120;

export type PairingAckVia = "handshake" | "sign-in";

export function ackFilePath(): string {
	return path.join(resolveWebNextDataDir(process.env), ACK_FILENAME);
}

export async function writePairingAck(
	userAgent: string | null,
	via: PairingAckVia,
): Promise<void> {
	const ack = {
		pairedAt: new Date().toISOString(),
		userAgent: (userAgent ?? "").slice(0, USER_AGENT_MAX),
		via,
	};
	await writeFile(ackFilePath(), `${JSON.stringify(ack)}\n`, { mode: 0o600 });
}

/** The latest ack, or nulls — never throws, never leaks anything else. */
export async function readPairingAck(): Promise<{
	pairedAt: string | null;
	userAgent: string;
}> {
	try {
		const raw = await readFile(ackFilePath(), "utf8");
		const parsed = JSON.parse(raw) as { pairedAt?: string; userAgent?: string };
		return {
			pairedAt: typeof parsed.pairedAt === "string" ? parsed.pairedAt : null,
			userAgent: typeof parsed.userAgent === "string" ? parsed.userAgent : "",
		};
	} catch {
		return { pairedAt: null, userAgent: "" };
	}
}
