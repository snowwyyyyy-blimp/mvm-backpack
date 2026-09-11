import { json, cors, gameServerUrl } from "../_lib";

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const token = url.searchParams.get("token");
  if (!token) {
    return json({ error: "missing_token" }, 400);
  }

  try {
    const upstream = new URL(`${gameServerUrl(env)}/api/items`);
    upstream.searchParams.set("token", token);

    const resp = await fetch(upstream.toString(), {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(8000),
    });

    const text = await resp.text();
    return new Response(text, {
      status: resp.status,
      headers: { "Content-Type": "application/json", ...cors() },
    });
  } catch (e) {
    console.error("items fetch failed", e);
    return json({ error: "game_unreachable" }, 502);
  }
}

export async function onRequestOptions() {
  return new Response(null, { status: 204, headers: cors() });
}