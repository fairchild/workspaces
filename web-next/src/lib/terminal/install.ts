/*
 * The ttyd + tmux installation contract for session sandboxes (#752): static
 * binaries into a user-writable dir (no sudo — the harness bootstrap seam runs
 * plain commands), idempotent so it can run both at template-bootstrap time
 * (baked into the reusable snapshot, the fast path) and lazily from the mint
 * route (the fallback for sandboxes built from a pre-terminal template).
 * The Vercel node22 runtime is Amazon Linux 2023 on amd64; neither tool is in
 * its repos, and the static builds have zero runtime deps (ported from web/).
 */

/** Where the terminal binaries live inside the sandbox. */
export const TERMINAL_BIN_DIR = "/vercel/sandbox/.terminal-bin";
export const TTYD_BIN = `${TERMINAL_BIN_DIR}/ttyd`;
export const TMUX_BIN = `${TERMINAL_BIN_DIR}/tmux`;

const TTYD_STATIC_URL =
	"https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64";
/** If this URL ever breaks, pythops/tmux-linux-binary is a known-good alternative. */
const TMUX_STATIC_URL =
	"https://github.com/mjakob-gh/build-static-tmux/releases/latest/download/tmux.linux-amd64.stripped.gz";

/** Idempotent install: a no-op when both binaries are already present. */
export const TERMINAL_INSTALL_SCRIPT = [
	"set -e",
	`mkdir -p ${TERMINAL_BIN_DIR}`,
	`if [ ! -x ${TTYD_BIN} ]; then`,
	`  curl -sfL ${TTYD_STATIC_URL} -o ${TTYD_BIN}`,
	`  chmod +x ${TTYD_BIN}`,
	"fi",
	`if [ ! -x ${TMUX_BIN} ]; then`,
	`  curl -sfL ${TMUX_STATIC_URL} -o ${TMUX_BIN}.gz`,
	`  gunzip -f ${TMUX_BIN}.gz`,
	`  chmod +x ${TMUX_BIN}`,
	"fi",
	"",
].join("\n");
