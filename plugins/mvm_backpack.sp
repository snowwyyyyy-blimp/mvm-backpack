#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <tf2_stocks>
#include <socket>
#include <tf2items>

#define PLUGIN_VERSION "1.0.0"

#define MAX_ITEMS     64
#define TOKEN_LENGTH  24
#define TOKEN_TTL     60
#define HTTP_BUF_SIZE 8192

enum ePool
{
    Pool_Aussie = 0,
    Pool_Golden
};

/* Per-item definition loaded from configs/mvm_rewards.cfg */
new String:g_sItemKey[MAX_ITEMS][32];
new String:g_sItemName[MAX_ITEMS][64];
new String:g_sItemClass[MAX_ITEMS][32];
new g_iItemIndex[MAX_ITEMS];
new g_iItemQuality[MAX_ITEMS];
new ePool:g_iItemPool[MAX_ITEMS];
new g_iItemCount;

/* ConVars */
new Handle:g_cvAussieChance;
new Handle:g_cvGoldenChance;
new Handle:g_cvServerPort;
new Handle:g_cvWebBaseUrl;

/* SQLite */
new Handle:g_hDb = INVALID_HANDLE;

/* Socket server */
Socket g_hListener = null;
new StringMap:g_hReqBuf;      /* key "SOCK:<id>" -> raw http bytes */
new StringMap:g_hReqCtx;      /* key "SOCK:<id>" -> bitflags: 1 = items ctx, 2 = give ctx */
new StringMap:g_hCtxSock;     /* key "CTX_ITEMS" / "CTX_GIVE" -> socket id string */
new StringMap:g_hCtxAuth;
new StringMap:g_hCtxItem;

/* Session tokens: token -> steamid  /  token -> expiry (unix) */
new StringMap:g_hTokenClient;
new StringMap:g_hTokenExpire;

/* Scratch buffer for building large async responses (main-thread only). */
new String:g_sJsonBuf[8192];

public Plugin:myinfo =
{
    name        = "MvM Backpack",
    author      = "mvm-backpack",
    description = "MvM mission rewards (australium / golden wrench) with in-game backpack and web MOTD",
    version     = PLUGIN_VERSION,
    url         = ""
};

public OnPluginStart()
{
    CreateConVar("sm_mvm_backpack_version", PLUGIN_VERSION, "MvM Backpack version", FCVAR_NOTIFY);

    g_cvAussieChance = CreateConVar("sm_mvm_backpack_aussie_chance", "10", "Chance (percent) of australium drop per mission", FCVAR_NOTIFY);
    g_cvGoldenChance = CreateConVar("sm_mvm_backpack_golden_chance", "1", "Chance (percent) of golden wrench drop per mission", FCVAR_NOTIFY);
    g_cvServerPort   = CreateConVar("sm_mvm_backpack_port", "8821", "TCP port for the backpack JSON API", FCVAR_PROTECTED);
    g_cvWebBaseUrl   = CreateConVar("sm_mvm_backpack_web_url", "http://127.0.0.1:8788", "Base URL of the Cloudflare Pages frontend (MOTD opens <url>?token=...)");

    AutoExecConfig(true, "mvm_backpack");

    RegConsoleCmd("sm_backpack", Command_Backpack, "Open your MvM backpack");
    RegConsoleCmd("sm_bp", Command_Backpack, "Open your MvM backpack");

    HookEvent("teamplay_round_win", Event_RoundWin);

    g_hReqBuf = new StringMap();
    g_hReqCtx = new StringMap();
    g_hCtxSock = new StringMap();
    g_hCtxAuth = new StringMap();
    g_hCtxItem = new StringMap();
    g_hTokenClient = new StringMap();
    g_hTokenExpire = new StringMap();

    new String:err[256];
    g_hDb = SQLite_UseDatabase("mvm_backpack", err, sizeof(err));
    if (g_hDb == INVALID_HANDLE)
    {
        LogError("[MvMBP] SQLite open failed: %s", err);
        return;
    }

    CreateBackpackSchema();

    /* Late load: nothing to restore, tokens are per request. */
}

CreateBackpackSchema()
{
    new String:q[512];
    Format(q, sizeof(q),
        "CREATE TABLE IF NOT EXISTS mvm_backpack (steamid CHAR(32) NOT NULL, item_key CHAR(32) NOT NULL, item_name VARCHAR(96) NOT NULL, item_class VARCHAR(32) NOT NULL, item_index INT NOT NULL, quality INT NOT NULL, pool INT NOT NULL, got_at INT NOT NULL, claimed_at INT NULL, PRIMARY KEY (steamid, item_key));");

    SQL_TQuery(g_hDb, DB_OnSchemaDone, q);
}

public DB_OnSchemaDone(Handle:owner, Handle:results, const String:error[], any:data)
{
    if (error[0])
    {
        LogError("[MvMBP] schema error: %s", error);
        return;
    }
    PrintToServer("[MvMBP] Database ready.");
}

public OnMapStart()
{
    LoadRewards();
    StartHttpServer();
}

/* ============================ Rewards ============================ */

LoadRewards()
{
    decl String:path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/mvm_rewards.cfg");

    if (!FileExists(path))
    {
        LogError("[MvMBP] Missing config: %s", path);
        return;
    }

    KeyValues kv = new KeyValues("Rewards");
    if (!kv.ImportFromFile(path))
    {
        LogError("[MvMBP] Failed to parse %s", path);
        CloseHandle(kv);
        return;
    }

    g_iItemCount = 0;

    if (KvJumpToKey(kv, "australium", false))
    {
        if (KvGotoFirstSubKey(kv, false))
        {
            do
            {
                RegisterItem(kv, Pool_Aussie);
            } while (KvGotoNextKey(kv, false));
        }
        KvRewind(kv);
    }

    if (KvJumpToKey(kv, "golden", false))
    {
        if (KvGotoFirstSubKey(kv, false))
        {
            do
            {
                RegisterItem(kv, Pool_Golden);
            } while (KvGotoNextKey(kv, false));
        }
        KvRewind(kv);
    }

    CloseHandle(kv);
    PrintToServer("[MvMBP] Loaded %d reward items.", g_iItemCount);
}

RegisterItem(Handle:kv, ePool:pool)
{
    if (g_iItemCount >= MAX_ITEMS)
        return;

    decl String:key[32];
    KvGetSectionName(kv, key, sizeof(key));

    KvGetString(kv, "name", g_sItemName[g_iItemCount], 64);
    KvGetString(kv, "class", g_sItemClass[g_iItemCount], 32, "tf_weapon_generic");
    g_iItemIndex[g_iItemCount]   = KvGetNum(kv, "index", 0);
    g_iItemQuality[g_iItemCount] = KvGetNum(kv, "quality", 11);
    g_iItemPool[g_iItemCount]    = pool;
    strcopy(g_sItemKey[g_iItemCount], 32, key);

    g_iItemCount++;
}

GetPoolCount(ePool:pool)
{
    new n = 0;
    for (new i = 0; i < g_iItemCount; i++)
        if (g_iItemPool[i] == pool)
            n++;
    return n;
}

GetRandomPoolItem(ePool:pool)
{
    new n = GetPoolCount(pool);
    if (n <= 0)
        return -1;

    new pick = GetRandomInt(0, n - 1);
    for (new i = 0; i < g_iItemCount; i++)
    {
        if (g_iItemPool[i] == pool)
        {
            if (pick == 0)
                return i;
            pick--;
        }
    }
    return -1;
}

/* ============================ Mission win ============================ */

public Action:Event_RoundWin(Handle:event, const String:name[], bool:dontBroadcast)
{
    /* MvM: humans are BLU (3), robots are RED (2). */
    if (GetEventInt(event, "winner") != _:TFTeam_Blue)
        return Plugin_Continue;

    new logic = FindEntityByClassname(-1, "tf_logic_mann_vs_machine");
    if (logic == -1)
        return Plugin_Continue;

    for (new client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))         continue;
        if (IsFakeClient(client))            continue;
        if (GetClientTeam(client) != _:TFTeam_Blue) continue;
        AwardRewards(client);
    }

    return Plugin_Continue;
}

AwardRewards(client)
{
    /* Golden WRENCH: 1% per mission (rarest). */
    new golden = GetConVarInt(g_cvGoldenChance);
    if (golden > 0 && GetRandomInt(1, 100) <= golden)
    {
        new idx = GetRandomPoolItem(Pool_Golden);
        if (idx != -1)
            AddToBackpack(client, idx);
        return; /* one reward per mission, per player */
    }

    /* Australium: 10% per mission. */
    new aussie = GetConVarInt(g_cvAussieChance);
    if (aussie > 0 && GetRandomInt(1, 100) <= aussie)
    {
        new idx = GetRandomPoolItem(Pool_Aussie);
        if (idx != -1)
            AddToBackpack(client, idx);
    }
}

AddToBackpack(client, idx)
{
    if (g_hDb == INVALID_HANDLE)
        return;

    decl String:authid[32];
    GetClientAuthId(client, AuthId_Steam3, authid, sizeof(authid), true);

    new String:q[600];
    Format(q, sizeof(q),
        "INSERT OR IGNORE INTO mvm_backpack (steamid, item_key, item_name, item_class, item_index, quality, pool, got_at) VALUES ('%s', '%s', '%s', '%s', %d, %d, %d, %d);",
        authid,
        g_sItemKey[idx],
        g_sItemName[idx],
        g_sItemClass[idx],
        g_iItemIndex[idx],
        g_iItemQuality[idx],
        _:g_iItemPool[idx],
        GetTime());

    SQL_TQuery(g_hDb, DB_OnInsertDone, q, idx);

    PrintToChat(client, " \x02[MvM Backpack]\x01 You earned: \x03%s\x01! Type \x02!backpack\x01 to claim it in-game.", g_sItemName[idx]);
    PrintToChatAll(" \x02[MvM Backpack]\x01 %N earned: \x03%s\x01!", client, g_sItemName[idx]);
}

public DB_OnInsertDone(Handle:owner, Handle:results, const String:error[], any:idx)
{
    if (error[0])
        LogError("[MvMBP] insert error: %s", error);
}

/* ============================ !backpack ============================ */

public Action:Command_Backpack(client, args)
{
    if (client == 0 || !IsClientInGame(client))
        return Plugin_Handled;

    decl String:authid[32];
    if (!GetClientAuthId(client, AuthId_Steam3, authid, sizeof(authid), true))
        return Plugin_Handled;

    decl String:token[TOKEN_LENGTH + 1];
    GenerateToken(token, sizeof(token));

    g_hTokenClient.SetString(token, authid);

    new String:expiry[16];
    IntToString(GetTime() + TOKEN_TTL, expiry, sizeof(expiry));
    g_hTokenExpire.SetString(token, expiry);

    decl String:base[256];
    GetConVarString(g_cvWebBaseUrl, base, sizeof(base));

    decl String:url[512];
    if (StrContains(base, "?") == -1)
        Format(url, sizeof(url), "%s?token=%s", base, token);
    else
        Format(url, sizeof(url), "%s&token=%s", base, token);

    ShowMOTDPanel(client, "MvM Backpack", url, MOTDPANEL_TYPE_URL);
    PrintToChat(client, " \x02[MvM Backpack]\x01 Backpack opened. Token expires in %d seconds.", TOKEN_TTL);

    return Plugin_Handled;
}

GenerateToken(String:buffer[], size)
{
    static const String:chars[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    for (new i = 0; i < size - 1; i++)
        buffer[i] = chars[GetRandomInt(0, sizeof(chars) - 2)];
    buffer[size - 1] = 0;
}

/* Validates the token. NOT consumed here — the frontend uses the same token
 * for GET /api/items and the subsequent POST /api/give, so it must stay valid
 * until its TTL expires. */
bool:ResolveToken(const String:token[], String:authidOut[], size)
{
    if (!g_hTokenClient.GetString(token, authidOut, size))
        return false;

    new String:expiryStr[16];
    if (!g_hTokenExpire.GetString(token, expiryStr, sizeof(expiryStr)))
        return false;

    if (GetTime() > StringToInt(expiryStr))
    {
        g_hTokenClient.Remove(token);
        g_hTokenExpire.Remove(token);
        return false;
    }

    return true;
}

/* ============================ Socket HTTP server ============================ */

StartHttpServer()
{
    if (g_hListener != null)
        g_hListener.Close();

    new port = GetConVarInt(g_cvServerPort);
    g_hListener = new Socket();
    if (g_hListener == null)
    {
        LogError("[MvMBP] couldn't create socket");
        return;
    }

    g_hListener.SetErrorCallback(OnSocketError);
    g_hListener.SetIncomingCallback(OnSocketIncoming);

    if (!g_hListener.Bind("0.0.0.0", port))
    {
        LogError("[MvMBP] couldn't bind port %d", port);
        g_hListener.Close();
        g_hListener = null;
        return;
    }

    g_hListener.Listen();
    PrintToServer("[MvMBP] Backpack API listening on TCP :%d", port);
}

public OnSocketError(Socket sock, const int errorType, const char[] errorMsg, any data)
{
    LogError("[MvMBP] socket error: %s", errorMsg);
}

public OnSocketIncoming(Socket server, Socket client, const char[] ip, int port, any data)
{
    new String:key[24];
    Format(key, sizeof(key), "SOCK:%d", _:client);

    g_hReqCtx.SetValue(key, 0);

    new String:empty[1];
    g_hReqBuf.SetString(key, empty);

    client.SetReceiveCallback(OnSocketReceive);
}

public OnSocketReceive(Socket sock, const char[] data, const int size, const char[] senderIP, int senderPort, any data2)
{
    new String:key[24];
    Format(key, sizeof(key), "SOCK:%d", _:sock);

    new any:ctx;
    if (!g_hReqCtx.GetValue(key, ctx))
        return; /* socket we did not set up */

    new String:buf[HTTP_BUF_SIZE];
    g_hReqBuf.GetString(key, buf, sizeof(buf));
    StrCat(buf, sizeof(buf), data);

    if (StrContains(buf, "\r\n\r\n") != -1)
    {
        HandleRequest(sock, key, buf);
    }
    else if (strlen(buf) >= HTTP_BUF_SIZE)
    {
        sock.Close();
        g_hReqBuf.Remove(key);
        g_hReqCtx.Remove(key);
    }
    else
    {
        g_hReqBuf.SetString(key, buf);
    }
}

/* Minimal HTTP/1.1 server: GET /api/items?token=..., POST /api/give {JSON} */
HandleRequest(Socket sock, const String:key[], const String:request[])
{
    decl String:requestLine[1024];
    new idx = BreakString(request, requestLine, sizeof(requestLine));
    if (idx == -1)
    {
        ReplyJSON(sock, 400, "{\"error\":\"bad_request\"}");
        CloseSockCleanup(sock);
        return;
    }

    decl String:method[16];
    new idx2 = SplitString(requestLine, " ", method, sizeof(method));
    if (idx2 == -1)
    {
        ReplyJSON(sock, 400, "{\"error\":\"bad_request\"}");
        CloseSockCleanup(sock);
        return;
    }

    /* Reset + sanity: requestLine is "GET /x HTTP/1.1" */
    decl String:path[512];
    new pathStart = idx2 + 1;
    new idx3 = SplitString(requestLine[pathStart], " ", path, sizeof(path));
    if (idx3 == -1)
    {
        ReplyJSON(sock, 400, "{\"error\":\"bad_request\"}");
        CloseSockCleanup(sock);
        return;
    }

    new String:body[512];
    body[0] = 0;
    new iBody = StrContains(request, "\r\n\r\n");
    if (iBody != -1)
    {
        new start = iBody + 4;
        new remaining = strlen(request) - start;
        new copyLen = remaining;
        if (copyLen >= sizeof(body))
            copyLen = sizeof(body) - 1;
        if (copyLen > 0)
        {
            strcopy(body, copyLen + 1, request[start]);
            body[copyLen] = 0;
        }
    }

    decl String:route[256];
    decl String:query[256];
    ParsePath(path, route, sizeof(route), query, sizeof(query));

    if (StrEqual(method, "GET") && StrEqual(route, "/api/items"))
    {
        /* async: socket closed in DB_OnItemsFetched */
        HandleItems(sock, query);
    }
    else if (StrEqual(method, "POST") && StrEqual(route, "/api/give"))
    {
        /* async: socket closed in DB_OnGiveLookup */
        HandleGive(sock, body);
    }
    else
    {
        if (StrEqual(method, "OPTIONS"))
            ReplyJSON(sock, 204, "");
        else
            ReplyJSON(sock, 404, "{\"error\":\"not_found\"}");

        CloseSockCleanup(sock);
    }
}

/* Closes the socket and removes all maps we keyed by it.
 * Async DB handlers must call this after their final ReplyJSON. */
CloseSockCleanup(Socket sock)
{
    if (sock == null)
        return;

    decl String:key[24];
    Format(key, sizeof(key), "SOCK:%d", _:sock);

    sock.Close();
    g_hReqBuf.Remove(key);
    g_hReqCtx.Remove(key);

    g_hCtxSock.Remove("CTX_ITEMS");
    g_hCtxAuth.Remove("CTX_ITEMS");
    g_hCtxSock.Remove("CTX_GIVE");
    g_hCtxAuth.Remove("CTX_GIVE");
    g_hCtxItem.Remove("CTX_GIVE");
}

ParsePath(const String:path[], String:route[], routeSize, String:query[], querySize)
{
    new iQ = StrContains(path, "?");
    if (iQ == -1)
    {
        strcopy(route, routeSize, path);
        query[0] = 0;
        return;
    }
    strcopy(route, iQ + 1, path);
    strcopy(query, querySize, path[iQ + 1]);
}

/* -------------------- GET /api/items -------------------- */

HandleItems(Socket sock, const String:query[])
{
    decl String:token[TOKEN_LENGTH + 1];
    GetQueryParam(query, "token", token, sizeof(token));
    if (token[0] == 0)
    {
        ReplyJSON(sock, 400, "{\"error\":\"missing_token\"}");
        CloseSockCleanup(sock);
        return;
    }

    decl String:authid[32];
    if (!ResolveToken(token, authid, sizeof(authid)))
    {
        ReplyJSON(sock, 401, "{\"error\":\"invalid_token\"}");
        CloseSockCleanup(sock);
        return;
    }

    /* Stash socket as int->string so the async query can reply. */
    new String:id[24];
    IntToString(_:sock, id, sizeof(id));
    g_hCtxSock.SetString("CTX_ITEMS", id);
    g_hCtxAuth.SetString("CTX_ITEMS", authid);

    new String:q[512];
    Format(q, sizeof(q),
        "SELECT item_key, item_name, item_class, item_index, quality, got_at, claimed_at FROM mvm_backpack WHERE steamid='%s' ORDER BY got_at DESC", authid);
    SQL_TQuery(g_hDb, DB_OnItemsFetched, q);
}

public DB_OnItemsFetched(Handle:owner, Handle:results, const String:error[], any:data)
{
    new String:authid[32];
    g_hCtxAuth.GetString("CTX_ITEMS", authid, sizeof(authid));

    new String:id[24];
    g_hCtxSock.GetString("CTX_ITEMS", id, sizeof(id));
    Socket sock = view_as<Socket>(StringToInt(id));

    if (error[0] || sock == null || authid[0] == 0)
    {
        LogError("[MvMBP] items query error: %s", error);
        g_hCtxSock.Remove("CTX_ITEMS");
        g_hCtxAuth.Remove("CTX_ITEMS");
        return;
    }

    /* Best-effort player name (only if they happen to be connected). */
    decl String:playerName[64];
    playerName[0] = 0;
    for (new i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        decl String:pid[32];
        if (!GetClientAuthId(i, AuthId_Steam3, pid, sizeof(pid), true)) continue;
        if (StrEqual(pid, authid))
        {
            GetClientName(i, playerName, sizeof(playerName));
            break;
        }
    }
    if (playerName[0] == 0)
        strcopy(playerName, sizeof(playerName), authid);

    decl String:nameEsc[96];
    EscapeJSON(playerName, nameEsc, sizeof(nameEsc));
    decl String:authEsc[64];
    EscapeJSON(authid, authEsc, sizeof(authEsc));

    g_sJsonBuf[0] = 0;
    new pos = 0;
    pos += Format(g_sJsonBuf[pos], sizeof(g_sJsonBuf) - pos, "{\"player\":{\"name\":\"%s\",\"steamid\":\"%s\"},\"items\":[", nameEsc, authEsc);

    new n = 0;
    while (SQL_FetchRow(results))
    {
        decl String:key[32];
        decl String:name[96];
        decl String:cls[32];
        SQL_FetchString(results, 0, key, sizeof(key));
        SQL_FetchString(results, 1, name, sizeof(name));
        SQL_FetchString(results, 2, cls, sizeof(cls));
        new index    = SQL_FetchInt(results, 3);
        new quality  = SQL_FetchInt(results, 4);
        new gotAt    = SQL_FetchInt(results, 5);
        new bool:claimed = !SQL_IsFieldNull(results, 6);

        decl String:keyEsc[64];
        decl String:nameEsc2[128];
        EscapeJSON(key, keyEsc, sizeof(keyEsc));
        EscapeJSON(name, nameEsc2, sizeof(nameEsc2));

        if (n > 0)
            pos += Format(g_sJsonBuf[pos], sizeof(g_sJsonBuf) - pos, ",");
        pos += Format(g_sJsonBuf[pos], sizeof(g_sJsonBuf) - pos,
            "{\"item_key\":\"%s\",\"name\":\"%s\",\"quality\":%d,\"got_at\":%d,\"claimed\":%s}",
            keyEsc, nameEsc2, quality, gotAt, claimed ? "true" : "false");
        n++;
    }

    pos += Format(g_sJsonBuf[pos], sizeof(g_sJsonBuf) - pos, "]}");

    ReplyJSON(sock, 200, g_sJsonBuf);
    CloseSockCleanup(sock);
}

/* -------------------- POST /api/give -------------------- */

HandleGive(Socket sock, const String:body[])
{
    decl String:token[TOKEN_LENGTH + 1];
    decl String:itemKey[32];
    GetJsonString(body, "token", token, sizeof(token));
    GetJsonString(body, "item_key", itemKey, sizeof(itemKey));

    if (token[0] == 0 || itemKey[0] == 0)
    {
        ReplyJSON(sock, 400, "{\"error\":\"missing_fields\"}");
        CloseSockCleanup(sock);
        return;
    }

    decl String:authid[32];
    if (!ResolveToken(token, authid, sizeof(authid)))
    {
        ReplyJSON(sock, 401, "{\"error\":\"invalid_token\"}");
        CloseSockCleanup(sock);
        return;
    }

    new String:id[24];
    IntToString(_:sock, id, sizeof(id));
    g_hCtxSock.SetString("CTX_GIVE", id);
    g_hCtxAuth.SetString("CTX_GIVE", authid);
    g_hCtxItem.SetString("CTX_GIVE", itemKey);

    new String:q[512];
    Format(q, sizeof(q),
        "SELECT item_key, item_name, item_class, item_index, quality, pool, claimed_at FROM mvm_backpack WHERE steamid='%s' AND item_key='%s'",
        authid, itemKey);
    SQL_TQuery(g_hDb, DB_OnGiveLookup, q);
}

public DB_OnGiveLookup(Handle:owner, Handle:results, const String:error[], any:data)
{
    decl String:authid[32];
    decl String:itemKey[32];
    g_hCtxAuth.GetString("CTX_GIVE", authid, sizeof(authid));
    g_hCtxItem.GetString("CTX_GIVE", itemKey, sizeof(itemKey));

    new String:id[24];
    g_hCtxSock.GetString("CTX_GIVE", id, sizeof(id));
    Socket sock = view_as<Socket>(StringToInt(id));

    if (error[0] || sock == null || authid[0] == 0 || itemKey[0] == 0)
    {
        LogError("[MvMBP] give lookup error: %s", error);
        CloseSockCleanup(sock);
        return;
    }

    if (!SQL_FetchRow(results))
    {
        ReplyJSON(sock, 404, "{\"error\":\"not_owned\"}");
        CloseSockCleanup(sock);
        return;
    }

    if (!SQL_IsFieldNull(results, 6))
    {
        ReplyJSON(sock, 409, "{\"error\":\"already_claimed\"}");
        CloseSockCleanup(sock);
        return;
    }

    /* Must be connected to receive it. */
    new client = FindClientByAuth(authid);
    if (client == 0)
    {
        ReplyJSON(sock, 409, "{\"error\":\"player_offline\"}");
        CloseSockCleanup(sock);
        return;
    }

    new pool   = SQL_FetchInt(results, 5);
    decl String:name[96];
    SQL_FetchString(results, 1, name, sizeof(name));
    decl String:cls[32];
    SQL_FetchString(results, 2, cls, sizeof(cls));
    new index   = SQL_FetchInt(results, 3);
    new quality = SQL_FetchInt(results, 4);

    /* Mark claimed, then hand out the weapon. */
    new String:q[512];
    Format(q, sizeof(q),
        "UPDATE mvm_backpack SET claimed_at=%d WHERE steamid='%s' AND item_key='%s' AND claimed_at IS NULL",
        GetTime(), authid, itemKey);
    SQL_TQuery(g_hDb, DB_OnClaimed, q);

    GiveItemInGame(client, name, cls, index, quality, _:pool);

    decl String:nameEsc[128];
    EscapeJSON(name, nameEsc, sizeof(nameEsc));
    new String:resp[256];
    Format(resp, sizeof(resp), "{\"ok\":true,\"name\":\"%s\"}", nameEsc);
    ReplyJSON(sock, 200, resp);
    CloseSockCleanup(sock);
}

public DB_OnClaimed(Handle:owner, Handle:results, const String:error[], any:data)
{
    if (error[0])
        LogError("[MvMBP] claim update error: %s", error);
}

FindClientByAuth(const String:authid[])
{
    for (new i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i))    continue;
        decl String:pid[32];
        if (!GetClientAuthId(i, AuthId_Steam3, pid, sizeof(pid), true)) continue;
        if (StrEqual(pid, authid))
            return i;
    }
    return 0;
}

FindItemByKey(const String:key[])
{
    for (new i = 0; i < g_iItemCount; i++)
        if (StrEqual(g_sItemKey[i], key))
            return i;
    return -1;
}

GiveItemInGame(client, String:name[], String:cls[], index, quality, pool)
{
    new Handle:item = TF2Items_CreateItem(OVERRIDE_ALL);
    if (item == INVALID_HANDLE)
        return;

    TF2Items_SetClassname(item, cls);
    TF2Items_SetItemIndex(item, index);
    TF2Items_SetLevel(item, 10);
    TF2Items_SetQuality(item, quality);

    new attribCount = 0;
    new attribDefs[MAX_ITEMS];
    new Float:attribVals[MAX_ITEMS];

    if (pool == _:Pool_Aussie)
    {
        /* Attribute 2027 = "is australium item" -> gold material. */
        attribDefs[attribCount] = 2027;
        attribVals[attribCount] = 1.0;
        attribCount++;
    }
    else if (pool == _:Pool_Golden)
    {
        /* Attribute 150 = "set_turn_to_gold". */
        attribDefs[attribCount] = 150;
        attribVals[attribCount] = 1.0;
        attribCount++;
    }

    TF2Items_SetNumAttributes(item, attribCount);
    for (new i = 0; i < attribCount; i++)
        TF2Items_SetAttribute(item, i, attribDefs[i], attribVals[i]);

    new weapon = TF2Items_GiveNamedItem(client, item);
    CloseHandle(item);

    if (weapon == -1)
    {
        LogMessage("[MvMBP] GiveNamedItem failed for %N (%s)", client, name);
    }
    else
    {
        new slot = GetWeaponSlotIndex(cls);
        if (slot != -1 && GetPlayerWeaponSlot(client, slot) == -1)
            EquipPlayerWeapon(client, weapon);
        PrintToChat(client, " \x02[MvM Backpack]\x01 Here is your \x03%s\x01!", name);
    }
}

GetWeaponSlotIndex(const String:cls[])
{
    if (StrEqual(cls, "tf_weapon_pipebomblauncher"))   return 1;
    if (StrEqual(cls, "tf_weapon_shotgun_pyro"))       return 1;
    if (StrEqual(cls, "tf_weapon_shotgun_soldier"))    return 1;

    if (StrContains(cls, "rocketlauncher")  != -1 ||
        StrContains(cls, "scattergun")      != -1 ||
        StrContains(cls, "minigun")         != -1 ||
        StrContains(cls, "flamethrower")    != -1 ||
        StrContains(cls, "sniperrifle")     != -1 ||
        StrContains(cls, "grenadelauncher") != -1 ||
        StrContains(cls, "syringegun")      != -1 ||
        StrContains(cls, "smg")             != -1 ||
        StrContains(cls, "shotgun_primary") != -1)   return 0;

    if (StrContains(cls, "pistol")    != -1 ||
        StrContains(cls, "shotgun")   != -1 ||
        StrContains(cls, "medigun")   != -1 ||
        StrContains(cls, "wrangler")  != -1)   return 1;

    if (StrContains(cls, "wrench")    != -1 ||
        StrContains(cls, "knife")     != -1 ||
        StrContains(cls, "bat")       != -1 ||
        StrContains(cls, "bottle")    != -1 ||
        StrContains(cls, "fists")     != -1 ||
        StrContains(cls, "melee")     != -1)   return 2;

    return -1;
}

/* ============================ HTTP reply ============================ */

ReplyJSON(Socket sock, code, const String:body[])
{
    decl String:phrase[32];
    switch (code)
    {
        case 200: strcopy(phrase, sizeof(phrase), "OK");
        case 201: strcopy(phrase, sizeof(phrase), "Created");
        case 204: strcopy(phrase, sizeof(phrase), "No Content");
        case 400: strcopy(phrase, sizeof(phrase), "Bad Request");
        case 401: strcopy(phrase, sizeof(phrase), "Unauthorized");
        case 404: strcopy(phrase, sizeof(phrase), "Not Found");
        case 409: strcopy(phrase, sizeof(phrase), "Conflict");
        case 500: strcopy(phrase, sizeof(phrase), "Internal Server Error");
        default:  strcopy(phrase, sizeof(phrase), "Error");
    }

    new String:resp[HTTP_BUF_SIZE];
    new pos = 0;
    pos += Format(resp[pos], sizeof(resp) - pos, "HTTP/1.1 %d %s\r\n", code, phrase);
    pos += Format(resp[pos], sizeof(resp) - pos, "Content-Type: application/json\r\n");
    pos += Format(resp[pos], sizeof(resp) - pos, "Content-Length: %d\r\n", code == 204 ? 0 : strlen(body));
    pos += Format(resp[pos], sizeof(resp) - pos, "Access-Control-Allow-Origin: *\r\n");
    pos += Format(resp[pos], sizeof(resp) - pos, "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n");
    pos += Format(resp[pos], sizeof(resp) - pos, "Access-Control-Allow-Headers: Content-Type\r\n");
    pos += Format(resp[pos], sizeof(resp) - pos, "Connection: close\r\n\r\n");
    if (code != 204)
        pos += Format(resp[pos], sizeof(resp) - pos, "%s", body);

    sock.Send(resp);
}

/* ============================ Parsing helpers ============================ */

GetQueryParam(const String:query[], const String:key[], String:out[], size)
{
    out[0] = 0;
    if (query[0] == 0)
        return;

    decl String:pairs[64][64];
    new count = ExplodeString(query, "&", pairs, 64, 64);
    for (new i = 0; i < count; i++)
    {
        new eq = StrContains(pairs[i], "=");
        if (eq == -1)
            continue;
        decl String:k[64];
        strcopy(k, eq + 1, pairs[i]);
        if (StrEqual(k, key))
        {
            strcopy(out, size, pairs[i][eq + 1]);
            URLDecode(out, size);
            return;
        }
    }
}

GetJsonString(const String:body[], const String:key[], String:out[], size)
{
    out[0] = 0;
    if (body[0] == 0)
        return;

    decl String:pattern[64];
    Format(pattern, sizeof(pattern), "\"%s\"", key);
    new iStart = StrContains(body, pattern);
    if (iStart == -1)
        return;

    iStart += strlen(pattern);
    iStart += 1; /* skip colon */

    while (body[iStart] == ' ' || body[iStart] == '\t')
        iStart++;

    if (body[iStart] != '"')
    {
        /* numeric/boolean literal */
        new iEnd = iStart;
        while (body[iEnd] != 0 && body[iEnd] != ',' && body[iEnd] != '}')
            iEnd++;
        new len = iEnd - iStart;
        if (len >= size) len = size - 1;
        if (len > 0)
            strcopy(out, len + 1, body[iStart]);
        return;
    }

    iStart++;
    new iEnd = iStart;
    while (body[iEnd] != 0 && body[iEnd] != '"')
        iEnd++;
    new len = iEnd - iStart;
    if (len >= size) len = size - 1;
    if (len > 0)
        strcopy(out, len + 1, body[iStart]);

    /* unescape the two common JSON escapes */
    ReplaceString(out, size, "\\\"", "\"");
    ReplaceString(out, size, "\\\\", "\\");
}

EscapeJSON(const String:input[], String:out[], size)
{
    new o = 0;
    for (new i = 0; input[i] != 0; i++)
    {
        if (o >= size - 2)
            break;
        switch (input[i])
        {
            case '"':  { out[o++] = '\\'; out[o++] = '"'; }
            case '\\': { out[o++] = '\\'; out[o++] = '\\'; }
            case '\n': { out[o++] = '\\'; out[o++] = 'n'; }
            case '\t': { out[o++] = '\\'; out[o++] = 't'; }
            default:
                out[o++] = input[i];
        }
    }
    out[o] = 0;
}

URLDecode(String:s[], size)
{
    new len = strlen(s);
    new read = 0;
    new write = 0;
    while (read < len)
    {
        if (s[read] == '%' && read + 2 < len)
        {
            new hi = HexDigit(s[read + 1]);
            new lo = HexDigit(s[read + 2]);
            if (hi != -1 && lo != -1)
            {
                s[write++] = hi * 16 + lo;
                read += 3;
                continue;
            }
        }
        else if (s[read] == '+')
        {
            s[write++] = ' ';
            read++;
            continue;
        }
        s[write++] = s[read++];
    }
    s[write] = 0;
}

HexDigit(c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}