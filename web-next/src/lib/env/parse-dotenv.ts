/*
 * Minimal .env parser that honors quoted values spanning multiple physical
 * lines — the shape a downloaded GitHub App private key (a multi-line PEM)
 * takes in .env.local. Double-quoted values unescape \n and \r; single- and
 * back-quoted values are literal; unquoted values are the rest of the line,
 * trimmed (no inline-comment stripping, matching the loader this replaces, so
 * an unquoted value containing `#` is preserved). A naive line-splitter
 * truncates a multi-line PEM to its "-----BEGIN …-----" header, which then
 * fails crypto.sign with "DECODER routines::unsupported" — the bug this fixes.
 *
 * Whole-line comments and blanks simply don't match the key=value shape and are
 * skipped. Precedence (which source wins) is the caller's concern.
 */
export function parseDotEnv(src: string): Record<string, string> {
	const out: Record<string, string> = {};
	const normalized = src.replace(/\r\n?/g, "\n");
	const LINE =
		/^[ \t]*(?:export[ \t]+)?([\w.-]+)[ \t]*=[ \t]*('(?:\\'|[^'])*'|"(?:\\"|[^"])*"|`(?:\\`|[^`])*`|[^\n]*)$/gm;
	let match: RegExpExecArray | null;
	while ((match = LINE.exec(normalized)) !== null) {
		const key = match[1];
		let value = (match[2] ?? "").trim();
		const quote = value[0];
		if (
			(quote === '"' || quote === "'" || quote === "`") &&
			value.length >= 2 &&
			value[value.length - 1] === quote
		) {
			value = value.slice(1, -1);
			if (quote === '"') {
				value = value.replace(/\\n/g, "\n").replace(/\\r/g, "\r");
			}
		}
		out[key] = value;
	}
	return out;
}
