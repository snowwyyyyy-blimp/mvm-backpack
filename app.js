"use strict";

const QUALITY_LABEL = {
  0: "Normal",
  1: "Genuine",
  3: "Vintage",
  5: "Unusual",
  6: "Unique",
  7: "Community",
  8: "Valve",
  9: "Self-Made",
  11: "Strange",
  13: "Haunted",
  15: "Decorated"
};

const QUALITY_CLASS = (q) => {
  switch (String(q)) {
    case "0": return "q-normal";
    case "1": return "q-genuine";
    case "3": return "q-vintage";
    case "5": return "q-unusual";
    case "6": return "q-unique";
    case "7": return "q-community";
    case "9": return "q-selfmade";
    case "11": return "q-strange";
    case "13": return "q-haunted";
    default: return "q-unique";
  }
};

const $ = (sel) => document.querySelector(sel);

const state = {
  token: new URLSearchParams(location.search).get("token") || "",
  items: []
};

const toast = (msg, type = "") => {
  const el = $("#toast");
  el.textContent = msg;
  el.className = `toast show ${type}`;
  clearTimeout(toast._t);
  toast._t = setTimeout(() => (el.className = "toast"), 3000);
};

async function jsonFetch(url, options = {}) {
  const res = await fetch(url, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options
  });
  let data = null;
  try { data = await res.json(); } catch (_) { /* ignore */ }
  if (!res.ok) throw new Error((data && data.error) || `Request failed (${res.status})`);
  return data;
}

function fmtDate(ts) {
  if (!ts) return "";
  const d = new Date(ts * 1000);
  return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

function render() {
  const grid = $("#items");
  const stats = $("#stats");

  if (!state.token) {
    stats.textContent = "";
    grid.innerHTML = "";
    $("#playerName").textContent = "No player";
    return;
  }

  const total = state.items.length;
  const unclaimed = total ? state.items.filter((i) => !i.claimed).length : 0;
  stats.textContent = total ? `${unclaimed} of ${total} unclaimed` : "";

  if (!total) {
    grid.innerHTML = `<div class="empty">No rewards yet. Beat MvM missions to earn items!</div>`;
    return;
  }

  grid.innerHTML = state.items
    .map((it) => {
      const claimed = !!it.claimed;
      const claimHtml = claimed
        ? `<div class="claim claimed">Claimed &#10003;</div>`
        : `<div class="claim">Claim in game &#x2794;</div>`;
      return `
      <div class="card ${claimed ? "claimed" : ""}" data-key="${escapeAttr(it.item_key)}" data-name="${escapeAttr(it.name)}" data-claimed="${claimed}">
        <div class="icon">&#128296;</div>
        <div class="name ${QUALITY_CLASS(it.quality)}">${escapeHtml(it.name)}</div>
        <div class="meta">
          <span class="q">${QUALITY_LABEL[it.quality] || it.quality}</span>
          <span class="date">${fmtDate(it.got_at)}</span>
        </div>
        ${claimHtml}
      </div>`;
    })
    .join("");
}

const escapeHtml = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const escapeAttr = (s) => escapeHtml(s);

async function loadItems(token) {
  const card = document.createElement("div");
  card.innerHTML = `<div class="empty">Loading backpack...</div>`;
  $("#items").replaceChildren(card);

  try {
    const data = await jsonFetch(`/api/items?token=${encodeURIComponent(token)}`);
    state.items = data.items || [];
    if (data.player && data.player.name) $("#playerName").textContent = data.player.name;
    render();
    $("#login").classList.add("hidden");
    $("#filterBar").classList.remove("hidden");
    $("#intro").classList.add("hidden");
  } catch (e) {
    toast(e.message || "Failed to load backpack", "error");
    $("#intro").classList.remove("hidden");
    $("#login").classList.remove("hidden");
  }
}

async function claimItem(itemKey, cardEl) {
  if (!state.token) return;
  cardEl.classList.add("claiming");
  try {
    await jsonFetch("/api/give", {
      method: "POST",
      body: JSON.stringify({ token: state.token, item_key: itemKey })
    });
    state.items = state.items.map((i) => (i.item_key === itemKey ? { ...i, claimed: true } : i));
    render();
    toast("Item spawned in your inventory!", "success");
  } catch (e) {
    if (e.message === "already_claimed") {
      state.items = state.items.map((i) => (i.item_key === itemKey ? { ...i, claimed: true } : i));
      render();
    } else {
      toast(e.message || "Could not claim item", "error");
      cardEl.classList.remove("claiming");
    }
  }
}

function onSearchInput(e) {
  const q = e.target.value.trim().toLowerCase();
  document.querySelectorAll(".card").forEach((el) => {
    el.style.display = el.dataset.name.toLowerCase().includes(q) ? "" : "none";
  });
}

function init() {
  $("#items").addEventListener("click", (e) => {
    const card = e.target.closest(".card");
    if (!card || card.dataset.claimed === "true") return;
    claimItem(card.dataset.key, card);
  });

  $("#loginBtn").addEventListener("click", () => {
    const token = $("#token").value.trim();
    if (!token) return toast("Paste the token first", "error");
    state.token = token;
    loadItems(token);
  });

  $("#token").addEventListener("keydown", (e) => {
    if (e.key === "Enter") $("#loginBtn").click();
  });

  $("#logoutBtn").addEventListener("click", () => {
    state.token = "";
    state.items = [];
    history.replaceState(null, "", location.pathname);
    $("#playerName").textContent = "No player";
    $("#search").value = "";
    render();
    $("#filterBar").classList.add("hidden");
    $("#intro").classList.remove("hidden");
    $("#login").classList.remove("hidden");
  });

  $("#search").addEventListener("input", onSearchInput);

  if (state.token) {
    loadItems(state.token);
  } else {
    $("#login").classList.remove("hidden");
  }
}

document.addEventListener("DOMContentLoaded", init);