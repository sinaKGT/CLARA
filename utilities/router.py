"""Route each voice turn to its agent's n8n webhook.

The speech pipeline can only point at ONE endpoint, but every agent has its own
webhook. This sits between them on :8090:

    pipeline :8765  ->  router :8090  ->  the agent's webhook (n8n)

The browser appends "[route:<webhook-url>]" and "[sid:<agent-id>]" to each
agent's system prompt. The pipeline passes instructions through untouched, the
router reads the markers, strips them so no model ever sees them, and forwards
the turn. Switching agents in the browser switches the destination - nothing
restarts, no config changes.

It also absorbs the awkward parts so the n8n side stays simple:
  * The workflow may respond with plain JSON or with SSE. The pipeline always
    asks for a stream; a JSON reply is converted into a one-chunk stream.
  * The workflow's reply can be a proper OpenAI completion, or just
    {"output": "..."} / {"text": "..."} - whatever the Respond node emits.
  * The pipeline's start-up warmup call (no marker yet) gets a stub reply.
  * Failures come back as SPOKEN text, so the agent says what is wrong instead
    of going silent.

n8n owns the conversation memory. The pipeline keeps its own rolling history and
would happily send all of it, which would put the same conversation in front of
the model twice - once from us, once from the Postgres Chat Memory node - and
they drift apart the moment either side trims. So the body is slimmed down to
exactly two messages before it leaves here:

    messages[0]  system   the agent's prompt
    messages[1]  user     what was just said, and nothing else

That is a contract, not an implementation detail: the n8n side can point at
those two fixed indexes forever. sessionId travels alongside for the memory
node's Session Key.

Runs on the pipeline's own venv - fastapi, httpx and uvicorn are already its
dependencies. No extra installs.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import re
from typing import Any, AsyncIterator

import httpx
import uvicorn
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse

PORT = int(os.environ.get("ROUTER_PORT", "8090"))
VERSION = 4   # bump when the forwarding contract changes
ROUTE = re.compile(r"\s*\[route:([^\]\s]+)\]")
SID   = re.compile(r"\s*\[sid:([^\]\s]+)\]")
SAFE_SID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

PG_CONTAINER = os.environ.get("CLARA_PG_CONTAINER", "clara-postgres")
PG_USER      = os.environ.get("CLARA_PG_USER", "clara")
PG_DB        = os.environ.get("CLARA_PG_DB", "agents")
PG_TABLE     = "n8n_chat_histories"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("router")

app = FastAPI(title="agent router")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
client = httpx.AsyncClient(timeout=httpx.Timeout(180.0, connect=5.0))


# ------------------------------------------------------------------ shapes
def completion(text: str) -> dict:
    return {"id": "router", "object": "chat.completion", "created": 0, "model": "router",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                         "finish_reason": "stop"}]}


def sse_of(text: str) -> str:
    head = {"id": "router", "object": "chat.completion.chunk", "created": 0, "model": "router",
            "choices": [{"index": 0, "delta": {"role": "assistant", "content": text},
                         "finish_reason": None}]}
    tail = {"id": "router", "object": "chat.completion.chunk", "created": 0, "model": "router",
            "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
    return f"data: {json.dumps(head)}\n\ndata: {json.dumps(tail)}\n\ndata: [DONE]\n\n"


def reply(text: str, streaming: bool):
    if streaming:
        return StreamingResponse(iter([sse_of(text)]), media_type="text/event-stream")
    return JSONResponse(completion(text))


def extract_text(data: Any) -> str | None:
    """Find the reply text in whatever shape the workflow returned."""
    if isinstance(data, list) and data:
        data = data[0]
    if not isinstance(data, dict):
        return None
    try:  # proper OpenAI shape first
        t = data["choices"][0]["message"]["content"]
        if isinstance(t, str) and t.strip():
            return t
    except (KeyError, IndexError, TypeError):
        pass
    for key in ("output", "text", "response", "reply", "content", "message"):
        v = data.get(key)
        if isinstance(v, str) and v.strip():
            return v
        if isinstance(v, dict):
            inner = extract_text(v)
            if inner:
                return inner
    return None


def take_markers(body: dict) -> tuple[str | None, str | None]:
    """Pull [route:...] and [sid:...] out of the messages, stripping them everywhere."""
    url = sid = None
    for m in body.get("messages") or []:
        c = m.get("content") if isinstance(m, dict) else None
        if not isinstance(c, str):
            continue
        if "[route:" in c:
            f = ROUTE.search(c)
            if f and not url:
                url = f.group(1)
            c = ROUTE.sub("", c)
        if "[sid:" in c:
            f = SID.search(c)
            if f and not sid:
                sid = f.group(1)
            c = SID.sub("", c)
        m["content"] = c.rstrip()
    return url, sid


def fallback_sid(url: str) -> str:
    """A session key for agents whose page predates the [sid:] marker. Each
    agent has its own webhook, so the URL is already a per-agent identity -
    hashing it gives a key that is stable across restarts and unique per agent.
    sessionId is therefore ALWAYS present downstream, never conditional."""
    return "a" + hashlib.sha1(url.encode("utf-8")).hexdigest()[:12]


def slim(body: dict, sid: str | None) -> dict:
    """Reduce to [system, latest user] - see the module docstring."""
    msgs = [m for m in (body.get("messages") or []) if isinstance(m, dict)]
    system = next((m for m in msgs if m.get("role") == "system"), None)
    latest = next((m for m in reversed(msgs) if m.get("role") == "user"), None)
    kept = [m for m in (system, latest) if m]

    out = {k: v for k, v in body.items() if k != "messages"}
    out["messages"] = kept or msgs
    # Both spellings: n8n expressions in the wild use either.
    out["sessionId"] = sid
    out["session_id"] = sid
    return out


def polish(text: str) -> str:
    """n8n hands back a leading '=' when a Respond node field is left in
    expression mode holding plain text. It is never speech - drop it."""
    t = text.strip()
    if t.startswith("=") and not t.startswith("=="):
        t = t[1:].lstrip()
    return t


# ------------------------------------------------------------------ memory
#
# Each agent's history is rows in n8n's own table, keyed by session_id. Wiping
# one agent is therefore a single scoped DELETE - no other agent is touched.
#
# psql is reached through "docker exec" rather than a Python driver on purpose:
# the pipeline's venv has no postgres client and adding one would mean a
# compiler and a wheel for something used a few times a year. Docker is already
# a hard requirement here, so this costs nothing.
async def psql(sql: str) -> tuple[bool, str]:
    try:
        proc = await asyncio.create_subprocess_exec(
            "docker", "exec", "-i", PG_CONTAINER,
            "psql", "-U", PG_USER, "-d", PG_DB, "-tA", "-c", sql,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, err = await asyncio.wait_for(proc.communicate(), timeout=20)
    except FileNotFoundError:
        return False, "Docker is not on PATH."
    except asyncio.TimeoutError:
        return False, "Postgres did not answer in time."
    except Exception as exc:
        return False, f"{type(exc).__name__}"
    if proc.returncode != 0:
        msg = (err or b"").decode("utf-8", "replace").strip().splitlines()
        detail = msg[-1] if msg else f"exit {proc.returncode}"
        if "No such container" in detail:
            detail = f"{PG_CONTAINER} is not running."
        return False, detail
    return True, (out or b"").decode("utf-8", "replace").strip()


def keys_for(body: dict) -> list[str]:
    """Every session_id this agent could have written under: the browser's agent
    id, and - for agents created before the [sid:] marker existed - the hash of
    its webhook that the router fell back to. Clearing has to cover both or a
    wipe silently leaves the older half behind."""
    keys = []
    sid = str(body.get("sid") or "").strip()
    if sid and SAFE_SID.match(sid):
        keys.append(sid)
    hook = str(body.get("webhook") or "").strip()
    if hook:
        keys.append(fallback_sid(hook))
    return list(dict.fromkeys(keys))


def in_list(keys: list[str]) -> str:
    return ",".join("'" + k.replace("'", "''") + "'" for k in keys)


@app.post("/memory/count")
async def memory_count(request: Request):
    try:
        body = await request.json()
    except Exception:
        return {"ok": False, "error": "Bad request."}
    keys = keys_for(body)
    if not keys:
        return {"ok": False, "error": "No session key for this agent."}
    ok, out = await psql(
        f"SELECT count(*) FROM {PG_TABLE} WHERE session_id IN ({in_list(keys)});")
    if not ok:
        if "does not exist" in out:
            return {"ok": True, "messages": 0}   # nothing has been stored yet
        return {"ok": False, "error": out}
    try:
        return {"ok": True, "messages": int(out.splitlines()[0])}
    except Exception:
        return {"ok": True, "messages": 0}


@app.post("/memory/clear")
async def memory_clear(request: Request):
    try:
        body = await request.json()
    except Exception:
        return {"ok": False, "error": "Bad request."}
    keys = keys_for(body)
    if not keys:
        return {"ok": False, "error": "No session key for this agent."}
    ok, out = await psql(
        f"DELETE FROM {PG_TABLE} WHERE session_id IN ({in_list(keys)});")
    if not ok:
        if "does not exist" in out:
            return {"ok": True, "deleted": 0}
        return {"ok": False, "error": out}
    # psql -tA prints "DELETE <n>"
    n = 0
    for line in out.splitlines():
        if line.startswith("DELETE"):
            try:
                n = int(line.split()[-1])
            except Exception:
                pass
    log.info("cleared %d rows for %s", n, ",".join(keys))
    return {"ok": True, "deleted": n}


# ------------------------------------------------------------------ routes
@app.get("/health")
async def health():
    return {"ok": True, "port": PORT, "version": VERSION,
            "contract": "messages=[system,user] + sessionId"}


@app.post("/test")
async def test(request: Request):
    """The wizard's Test button. Sends one real turn to a webhook and reports
    exactly what a voice turn would experience."""
    try:
        body = await request.json()
    except Exception:
        return {"ok": False, "error": "Bad request."}
    url = str(body.get("url") or "").strip()
    if not url.lower().startswith("http"):
        return {"ok": False, "error": "That does not look like a URL."}

    probe = {"model": "test", "stream": False, "sessionId": "router-test", "session_id": "router-test",
             "messages": [{"role": "system", "content": "You are a voice agent. Keep replies short."},
                          {"role": "user", "content": "Say one short sentence to confirm you can hear me."}]}
    try:
        r = await client.post(url, json=probe, timeout=90.0)
    except httpx.ConnectError:
        return {"ok": False, "error": "Not reachable. Is n8n running?"}
    except httpx.TimeoutException:
        return {"ok": False, "error": "Timed out after 90 s. The workflow may be stuck."}
    except Exception as exc:
        return {"ok": False, "error": f"{type(exc).__name__}"}

    if r.status_code == 404:
        return {"ok": False, "error": "404 - webhook not found. Is the workflow ACTIVE, and is this the Production URL?"}
    if r.status_code >= 400:
        return {"ok": False, "error": f"The workflow returned HTTP {r.status_code}.", "raw": r.text[:300]}

    if "text/event-stream" in r.headers.get("content-type", ""):
        parts = []
        for line in r.text.splitlines():
            if line.startswith("data:") and "[DONE]" not in line:
                try:
                    d = json.loads(line[5:])
                    parts.append(d["choices"][0]["delta"].get("content") or "")
                except Exception:
                    pass
        text = polish("".join(parts))
        if text:
            return {"ok": True, "reply": text, "streaming": True}
        return {"ok": False, "error": "Streamed, but no text found in the stream."}

    try:
        data = r.json()
    except Exception:
        return {"ok": False, "error": "The reply was not JSON.", "raw": r.text[:300]}
    text = extract_text(data)
    if text:
        return {"ok": True, "reply": polish(text), "streaming": False}
    return {"ok": False, "error": "Replied, but I could not find any text in it.",
            "raw": json.dumps(data)[:300]}


@app.post("/v1/chat/completions")
async def chat(request: Request):
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": {"message": "invalid JSON"}}, status_code=400)

    streaming = bool(body.get("stream"))
    url, sid = take_markers(body)

    if not url:
        # The pipeline warms the LLM up at start, before any agent is selected.
        return reply("OK.", streaming)

    outbound = slim(body, sid or fallback_sid(url))
    try:
        req = client.build_request("POST", url, json=outbound,
                                   headers={"content-type": "application/json"})
        upstream = await client.send(req, stream=True)
    except Exception as exc:
        log.warning("cannot reach %s: %s", url, exc)
        return reply("I could not reach my workflow. Check that n8n is running.", streaming)

    ctype = upstream.headers.get("content-type", "")
    if upstream.status_code >= 400:
        await upstream.aread()
        await upstream.aclose()
        log.warning("%s -> %s", url, upstream.status_code)
        if upstream.status_code == 404:
            return reply("My workflow was not found. It may not be active.", streaming)
        return reply(f"My workflow returned an error, code {upstream.status_code}.", streaming)

    if "text/event-stream" in ctype:
        # The workflow streams: relay the bytes untouched.
        async def relay() -> AsyncIterator[bytes]:
            try:
                async for chunk in upstream.aiter_raw():
                    yield chunk
            finally:
                await upstream.aclose()
        return StreamingResponse(relay(), media_type="text/event-stream")

    raw = await upstream.aread()
    await upstream.aclose()
    try:
        data = json.loads(raw)
    except Exception:
        return reply("My workflow sent something I could not read.", streaming)
    text = extract_text(data)
    if not text:
        return reply("My workflow replied without any text.", streaming)
    text = polish(text)
    log.info("%s -> %d chars", url.split("/")[-1], len(text))
    return reply(text, streaming)


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
