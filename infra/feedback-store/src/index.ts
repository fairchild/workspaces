import { handleAdmin } from "./admin";
import { handleAgentAPI } from "./agent-api";
import { handlePublish } from "./publish";
import { handleSubmit } from "./submit";
import type { Env } from "./types";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    try {
      if (request.method === "GET" && url.pathname === "/health") {
        return new Response("ok", { status: 200 });
      }

      if (request.method === "POST" && url.pathname === "/feedback") {
        return handleSubmit(request, env);
      }

      if (url.pathname.startsWith("/api/")) {
        return handleAgentAPI(request, env);
      }

      if (url.pathname === "/admin/publish" && request.method === "POST") {
        return handlePublish(request, env);
      }

      if (url.pathname.startsWith("/admin")) {
        return handleAdmin(request, env);
      }

      return new Response("not found", { status: 404 });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return Response.json({ error: message }, { status: 500 });
    }
  },
} satisfies ExportedHandler<Env>;
