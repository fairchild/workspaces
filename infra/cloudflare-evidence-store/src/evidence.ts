/**
 * Pure helpers and limits for the evidence store.
 *
 * These live outside `index.ts` because the Workers runtime rejects any named
 * export from the entry module that is not a function or an ExportedHandler —
 * a `export const MAX_UPLOAD_BYTES` there stops `wrangler dev` from starting at
 * all, so the worker could not be exercised locally.
 */

export const MAX_UPLOAD_BYTES = 50 * 1024 * 1024;

/** Bytes of entropy in the minted key segment; 16 gives a 22-character token. */
const KEY_ENTROPY_BYTES = 16;

const encoder = new TextEncoder();

export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  const aBytes = encoder.encode(a);
  const bBytes = encoder.encode(b);
  let result = 0;
  for (let i = 0; i < aBytes.length; i++) {
    result |= aBytes[i] ^ bBytes[i];
  }
  return result === 0;
}

/**
 * An unguessable path segment, so a stored object's URL cannot be reached by
 * anyone who merely knows the repo, PR number and slug the uploader chose.
 */
export function mintKeySegment(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(KEY_ENTROPY_BYTES));
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/**
 * Insert the minted segment directly above the filename, so the caller's
 * `repo/pr-N/` grouping still reads at a glance while the full path stays
 * unguessable.
 */
export function mintKey(requestedPath: string, segment: string): string {
  const cut = requestedPath.lastIndexOf("/");
  if (cut === -1) return `${segment}/${requestedPath}`;
  return `${requestedPath.slice(0, cut)}/${segment}/${requestedPath.slice(cut + 1)}`;
}

const CONTENT_TYPES: Record<string, string> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  svg: "image/svg+xml",
  txt: "text/plain",
  json: "application/json",
  webm: "video/webm",
  mp4: "video/mp4",
};

export function contentTypeFromPath(path: string): string {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return CONTENT_TYPES[ext] ?? "application/octet-stream";
}

/**
 * The declared body size, or the response to send instead. Cloudflare presents
 * a Content-Length to the Worker even when the client streams without one, so
 * this rejects oversize bodies before any of them reaches R2.
 */
export function declaredUploadLength(request: Request): number | Response {
  const raw = request.headers.get("Content-Length");
  if (raw === null) {
    return new Response("Content-Length is required", { status: 411 });
  }
  if (!/^\d+$/.test(raw)) {
    return new Response("invalid Content-Length", { status: 400 });
  }
  const length = Number(raw);
  if (!Number.isSafeInteger(length)) {
    return new Response("invalid Content-Length", { status: 400 });
  }
  if (length > MAX_UPLOAD_BYTES) {
    return new Response("upload exceeds the 50 MiB limit", { status: 413 });
  }
  return length;
}
