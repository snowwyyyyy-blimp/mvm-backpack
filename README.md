# MvM Backpack

Custom reward system for a Team Fortress 2 Mann-vs-Machine server:
on every won mission, each player has a chance to win an **Australium weapon**
(10% default) or the **Golden Wrench** (1% default). Drops are stored on the
server in SQLite. Players run `!backpack` in-game to open a web MOTD where
they can claim each unclaimed drop — the item is then given directly into
their backpack via `TF2Items_GiveNamedItem`.

## Architecture

```
 TF2 server (SourceMod)                     Cloudflare Pages
+------------------------------------+      +----------------------------------------------+
| mvm_backpack.smx                   |      | MOTD page (index.html, styles.css, app.js)    |
|  - awards drops on win (SQLite)    |      |   ?token=... opens the backpack               |
|  - opens MOTD with per-player      |----->| Functions proxy:                              |
|    token (?token=ABCDEF1234)       |      |   GET  /api/items?token=<>  -> /api/items    |
|  - TCP JSON API on :8821 (Socket)  |<-----|   POST /api/give{token,item_key} -> /api/give |
|    /api/items  GET  -> unclaimed   |      |   GAME_SERVER_URL env var (default: http://    |
|    /api/give   POST -> give item   |      |   127.0.0.1:8821)                              |
+------------------------------------+      +----------------------------------------------+
```

The game server must be reachable from Cloudflare (public IP **or** a
`cloudflared` tunnel — see `cloudflared/config.yml`).

## Repository layout

- `plugins/mvm_backpack.sp` — the SourceMod plugin (classic syntax).
- `plugins/configs/mvm_rewards.cfg` — reward pool, per-item quality.
- `plugins/schema.sql` — reference schema (the plugin creates the table itself).
- `index.html`, `styles.css`, `app.js` — MOTD frontend (static, no build step).
- `functions/` — Cloudflare Pages Functions (request proxy to the game server).
- `cloudflared/config.yml` — example tunnel config to expose the game API.

## API contract

`GET /api/items?token=<token>` returns

```json
{
  "player": { "name": "Jon", "steamid": "STEAM_1:0:1234" },
  "items": [
    { "item_key": "scattergun", "name": "Australium Scattergun",
      "quality": 11, "got_at": 1690000000, "claimed": false }
  ]
}
```

`POST /api/give` `{ "token": "<token>", "item_key": "<key>" }`

| HTTP | `error`          | meaning                                        |
|------|------------------|------------------------------------------------|
| 200  | —                | item given in-game (`{ "ok": true, "name": "..." }`) |
| 400  | `missing_*`/`bad_*` | malformed request                            |
| 401  | `invalid_token`/`expired_token` | bad/expired token (60s TTL) |
| 404  | `player_offline`  | requesting player is no longer on the server  |
| 404  | `unknown_item`    | `item_key` not in config                      |
| 409  | `already_claimed` | this drop was already claimed                 |
| 502  | `game_unreachable`| Cloudflare could not reach the game server    |

Tokens are single-use-per-session valid for 60 seconds (the MOTD reuses the
same token for `GET /api/items` and the `POST /api/give`).

## Server installation

1. Install the **Socket** extension and the **TF2Items** extension
   (both from the [AlliedModders](https://alliedmods.net) forums; latest
   snapshots from `https://builds.limetech.io`).
2. Compile `plugins/mvm_backpack.sp` with `spcomp` (classic syntax only —
   no `newdecls required`) and put the resulting `mvm_backpack.smx` in
   `addons/sourcemod/plugins/`. Alternative: put the `.sp` in
   `addons/sourcemod/scripting/` and build from the server's plugin compiler
   (Linux TF2 servers usually have `scripting/spcomp` available).
3. Copy `plugins/configs/mvm_rewards.cfg` to `addons/sourcemod/configs/`.
4. Load the plugin (`sm plugins load mvm_backpack`). The SQLite database
   (`mvm_backpack.db`) is created automatically in `addons/sourcemod/data/`.
   The `items_game_item_2027` attribute ("is australium item") applies the
   gold material; it is already present in TF2's item definitions.
5. Windows servers: the TCP listener binds by default to
   `127.0.0.1:8821` (see ConVars) — port-forward/firewall accordingly.

### ConVars

| ConVar                            | default | description                                  |
|-----------------------------------|---------|----------------------------------------------|
| `sm_mvm_backpack_aussie_chance`   | `10`    | % chance of an australium drop per mission   |
| `sm_mvm_backpack_golden_chance`   | `1`     | % chance of a golden wrench drop per mission |
| `sm_mvm_backpack_golden_once`     | `1`     | golden wrench only once per player?          |
| `sm_mvm_backpack_token_ttl`       | `60`    | MOTD token validity in seconds               |
| `sm_mvm_backpack_host`            | `127.0.0.1` | API bind address                     |
| `sm_mvm_backpack_port`            | `8821`  | API TCP port                                  |

### Admins

- `sm_mvm_backpack_reset <steamid>` — clear that player's pending rewards.
- `sm_mvm_backpack_reload` — reload `mvm_rewards.cfg`.

## Frontend / Functions deployment

The MOTD is a plain static site + Pages Functions — no build step.

```bash
npm i -g wrangler
npx wrangler pages dev .            # local test (uses .dev.vars)
npx wrangler pages deploy . --project-name mvm-backpack
```

Set the `GAME_SERVER_URL` **Pages environment variable**:

- Game server behind a public IP: `http://<server-ip>:8821`
- Otherwise use a cloudflared tunnel (see `cloudflared/config.yml`) and set it
  to the public tunnel URL, e.g. `https://mvm-api.example.com`.

Local testing with `wrangler pages dev` reads `GAME_SERVER_URL` from
`.dev.vars` (copy `.dev.vars.example`).

## Configuration

`mvm_rewards.cfg` defines two pools. Attributes are added automatically on
claim: australium items get attribute `2027` (gold material); the golden
wrench gets attribute `150` (turn-to-gold kill effect).

Quality numbers follow the TF2 item-schema enum — notably `11` = Strange
(choose `5` = Unusual for a fancier golden wrench).

```text
"australium" pool  — e.g. "Australium Rocket Launcher"  (index 18, quality 11, class tf_weapon_rocketlauncher)
"golden"     pool  — e.g. "Golden Wrench"               (index 169, quality 5,  class tf_weapon_wrench)
```

## Security notes

- Tokens only authorize listing/giving items **for that SteamID**; claiming is
  bound to the authenticated player. Keep the MOTD URL sharing in mind
  (60-second expiry limits exposure).
- The Functions proxy ships `Access-Control-Allow-Origin: *`. If you want to
  restrict it, harden `functions/_lib.js`.
- Bind the TCP API to `127.0.0.1` and expose it only through the tunnel /
  firewall rules you control.