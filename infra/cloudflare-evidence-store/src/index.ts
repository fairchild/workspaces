interface Env {
  EVIDENCE_BUCKET: R2Bucket;
  EVIDENCE_UPLOAD_TOKEN: string;
}

const encoder = new TextEncoder();

export const MAX_UPLOAD_BYTES = 50 * 1024 * 1024;

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  const aBytes = encoder.encode(a);
  const bBytes = encoder.encode(b);
  let result = 0;
  for (let i = 0; i < aBytes.length; i++) {
    result |= aBytes[i] ^ bBytes[i];
  }
  return result === 0;
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

function contentTypeFromPath(path: string): string {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return CONTENT_TYPES[ext] ?? "application/octet-stream";
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname.slice(1); // strip leading /

    if (request.method === "GET" && path === "health") {
      return new Response("ok", { status: 200 });
    }

    if (request.method === "GET" && path) {
      const object = await env.EVIDENCE_BUCKET.get(path);
      if (!object) {
        return new Response("not found", { status: 404 });
      }
      return new Response(object.body, {
        headers: {
          "Content-Type":
            object.httpMetadata?.contentType ?? contentTypeFromPath(path),
          "Cache-Control": "public, max-age=31536000, immutable",
          "Access-Control-Allow-Origin": "*",
        },
      });
    }

    if (request.method === "PUT" && path) {
      const auth = request.headers.get("Authorization");
      if (!auth || !timingSafeEqual(auth, `Bearer ${env.EVIDENCE_UPLOAD_TOKEN}`)) {
        return new Response("unauthorized", { status: 401 });
      }

      const declaredLength = Number(request.headers.get("Content-Length"));
      if (Number.isFinite(declaredLength) && declaredLength > MAX_UPLOAD_BYTES) {
        return new Response("upload exceeds the 50 MiB limit", { status: 413 });
      }

      const contentType =
        request.headers.get("Content-Type") ?? contentTypeFromPath(path);
      const body = await request.arrayBuffer();
      if (body.byteLength > MAX_UPLOAD_BYTES) {
        return new Response("upload exceeds the 50 MiB limit", { status: 413 });
      }

      await env.EVIDENCE_BUCKET.put(path, body, {
        httpMetadata: { contentType },
      });

      const publicUrl = `https://${url.hostname}/${path}`;
      return Response.json({ url: publicUrl }, { status: 201 });
    }

    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type",
        },
      });
    }

    return new Response("not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
