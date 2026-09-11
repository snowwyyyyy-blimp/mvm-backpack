export function cors() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  };
}

export function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...cors() },
  });
}

// Address of the SourceMod socket JSON API on the game server.
// Override with the GAME_SERVER_URL Pages environment variable.
export function gameServerUrl(env) {
  return env.GAME_SERVER_URL || "http://127.0.0.1:8821";
}