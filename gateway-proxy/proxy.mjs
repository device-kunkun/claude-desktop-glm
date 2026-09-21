// Local inference-gateway shim for Claude Desktop (custom-3p / gateway mode).
//
// Reverse-engineering finding (app.asar, gateway /v1/models page parser):
//   let t = e ? CPt(e.id) : void 0;  if (!e || !t) return [];      // CPt: string, len<=255
//   let n = o(e.anthropic_family_tier);                            // must be in Ho = [sonnet,opus,haiku,fable,mythos]
//   if (!Go(t.id) && !n) return [];                                // unknown family pattern AND no tier -> dropped
// => GLM model ids fail Go(t.id), so every entry needs a valid
//    anthropic_family_tier field to survive the "usable models" filter.
// This proxy injects that field and streams everything else verbatim
// to the GLM Anthropic-compatible endpoint.

import http from "node:http";
import { Readable } from "node:stream";

const LISTEN_HOST = "127.0.0.1";
const LISTEN_PORT = 8787;
const UPSTREAM = "https://open.bigmodel.cn/api/anthropic";
const LOG = (...a) => console.log(new Date().toISOString(), ...a);

// Map a GLM model id to one of the tiers the desktop accepts.
function tierFor(id) {
  const s = String(id).toLowerCase();
  if (s.includes("air") || s.includes("flash") || s.includes("lite")) return "haiku";
  if (/4\.5|4\.5v/.test(s)) return "sonnet";
  return "opus"; // flagship (glm-4.6, glm-4.7, ...) maps to the opus family
}

const HOP = new Set([
  "host", "connection", "content-length", "transfer-encoding", "keep-alive",
  "upgrade", "proxy-authenticate", "proxy-authorization", "te", "trailers",
]);

function forwardHeaders(h) {
  const out = {};
  for (const [k, v] of Object.entries(h)) {
    if (!HOP.has(k.toLowerCase())) out[k] = v;
  }
  return out;
}

async function handleModels(req, res, url) {
  const headers = forwardHeaders(req.headers);
  let upstreamRes;
  try {
    upstreamRes = await fetch(UPSTREAM + url.pathname + url.search, {
      method: "GET",
      headers,
    });
  } catch (e) {
    LOG("models upstream error:", e.message);
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ type: "error", error: { type: "api_error", message: "upstream unreachable: " + e.message } }));
    return;
  }
  const body = await upstreamRes.text();
  if (!upstreamRes.ok) {
    LOG("models upstream HTTP", upstreamRes.status, body.slice(0, 200));
    res.writeHead(upstreamRes.status, { "content-type": "application/json" });
    res.end(body);
    return;
  }
  let data;
  try {
    data = JSON.parse(body);
  } catch {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ type: "error", error: { type: "api_error", message: "upstream models not JSON" } }));
    return;
  }
  if (Array.isArray(data?.data)) {
    for (const m of data.data) {
      if (m && typeof m.id === "string" && !m.anthropic_family_tier) {
        m.anthropic_family_tier = tierFor(m.id);
      }
    }
    LOG(`models: injected family tier into ${data.data.length} entries`);
  }
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify(data));
}

async function handlePass(req, res, url) {
  const headers = forwardHeaders(req.headers);
  headers["accept-encoding"] = "identity"; // keep SSE uncompressed for easy streaming
  let bodyStream;
  if (req.method !== "GET" && req.method !== "HEAD") {
    bodyStream = Readable.toWeb(req);
  }
  let upstreamRes;
  try {
    upstreamRes = await fetch(UPSTREAM + url.pathname + url.search, {
      method: req.method,
      headers,
      body: bodyStream,
      duplex: "half",
    });
  } catch (e) {
    LOG("pass upstream error:", req.method, url.pathname, e.message);
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ type: "error", error: { type: "api_error", message: "upstream unreachable: " + e.message } }));
    return;
  }
  LOG("pass:", req.method, url.pathname, "->", upstreamRes.status);
  const resHeaders = {};
  upstreamRes.headers.forEach((v, k) => {
    if (!HOP.has(k.toLowerCase())) resHeaders[k] = v;
  });
  res.writeHead(upstreamRes.status, resHeaders);
  if (!upstreamRes.body) {
    res.end();
    return;
  }
  const reader = upstreamRes.body.getReader();
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!res.write(value)) {
        await new Promise((ok) => res.once("drain", ok));
      }
    }
    res.end();
  } catch (e) {
    LOG("stream aborted:", e.message);
    res.destroy();
  }
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://" + LISTEN_HOST + ":" + LISTEN_PORT);
  if (url.pathname === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
    return;
  }
  if (url.pathname.endsWith("/v1/models") && req.method === "GET") {
    handleModels(req, res, url).catch((e) => {
      LOG("models handler crash:", e.message);
      try { res.destroy(); } catch {}
    });
    return;
  }
  handlePass(req, res, url).catch((e) => {
    LOG("pass handler crash:", e.message);
    try { res.destroy(); } catch {}
  });
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  LOG(`gateway shim listening on http://${LISTEN_HOST}:${LISTEN_PORT} -> ${UPSTREAM}`);
});
