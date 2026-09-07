import {
  contentTypeFromPath,
  declaredUploadLength,
  mintKey,
  mintKeySegment,
  timingSafeEqual,
} from "./evidence.ts";

interface Env {
  EVIDENCE_BUCKET: R2Bucket;
  EVIDENCE_UPLOAD_TOKEN: string;
}

function isAuthorized(request: Request, env: Env): boolean {
  const auth = request.headers.get("Authorization");
  return !!auth && timingSafeEqual(auth, `Bearer ${env.EVIDENCE_UPLOAD_TOKEN}`);
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
      if (!isAuthorized(request, env)) {
        return new Response("unauthorized", { status: 401 });
      }

      const declaredLength = declaredUploadLength(request);
      if (declaredLength instanceof Response) return declaredLength;
      if (declaredLength > 0 && !request.body) {
        return new Response("request body is required", { status: 400 });
      }

      const contentType =
        request.headers.get("Content-Type") ?? contentTypeFromPath(path);

      const key = mintKey(path, mintKeySegment());
      await env.EVIDENCE_BUCKET.put(key, request.body, {
        httpMetadata: { contentType },
      });

      // The stored key is not the requested path, so callers must read the URL
      // from this response rather than reconstructing it from what they sent.
      return Response.json({ url: `https://${url.hostname}/${key}`, key }, { status: 201 });
    }

    // Withdrawing an upload needs the same token that made it. Deletes are
    // idempotent: a caller holding the token learns nothing from a 204 on a key
    // that was already gone.
    if (request.method === "DELETE" && path) {
      if (!isAuthorized(request, env)) {
        return new Response("unauthorized", { status: 401 });
      }
      await env.EVIDENCE_BUCKET.delete(path);
      return new Response(null, { status: 204 });
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
