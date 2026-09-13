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

// An uploaded HTML file is an active page on the origin every screenshot is
// served from, so every object carries a policy that lets it show images, this
// store's own video, and inline style, and nothing more. A browser plays a
// directly opened recording through a <video> element this policy governs, so
// `media-src 'self'` is what keeps a .webm link from opening a dead player.
// `sandbox` must arrive as a header — a page's own <meta> policy cannot set it —
// and it runs the page in an opaque origin with no script, form submission,
// popups, or plugins, whatever the page says.
const SERVED_OBJECT_HEADERS = {
  "Cache-Control": "public, max-age=31536000, immutable",
  "Access-Control-Allow-Origin": "*",
  "Content-Security-Policy": [
    "default-src 'none'",
    "img-src 'self' https://evidence.cloudcompute.com https://github.com https://*.githubusercontent.com data:",
    "media-src 'self'",
    "style-src 'unsafe-inline'",
    "base-uri 'none'",
    "form-action 'none'",
    "sandbox",
  ].join("; "),
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
};

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
          ...SERVED_OBJECT_HEADERS,
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

      // The stored key is not the requested path, so callers must read `key`
      // from this response rather than reconstructing it from what they sent.
      // Address the object as `<the base URL you dialed>/<key>`. The `url`
      // below is a convenience for the common case and nothing more: it
      // hardcodes https, drops the port, and under `wrangler dev` reports the
      // routed custom domain, so it is right only for production and preview.
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
