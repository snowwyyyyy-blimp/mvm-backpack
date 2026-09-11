import { json, cors, gameServerUrl } from "../_lib";

export async function onRequestPost({ request, env }) {
  let body;
  try {
    body = await request.json();
  } catch (_) {
    return json({ error: "bad_json" }, 400);
  }

  const token = typeof body.token === "string" ? body.token : "";
  const itemKey = typeof body.item_key === "string" ? body.item_key : "";

  if (!token || !itemKey) {
    return json({ error: "missing_fields" }, 400);
  }

  try {
    const resp = await fetch(`${gameServerUrl(env)}/api/give`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ token, item_key: itemKey }),
      signal: AbortSignal.timeout(8000),
    });

    const text = await resp.text();
    return new Response(text, {
      status: resp.status,
      headers: { "Content-Type": "application/json", ...cors() },
    });
  } catch (e) {
    console.error("give fetch failed", e);
    return json({ error: "game_unreachable" }, 502);
  }
}

export async function onRequestOptions() {
  return new Response(null, { status: 204, headers: cors() });
}