"""Hermes voice sidecar.

Fast voice / slow brain: a fast Foundry chat model answers in character and
decides (via a leading tag) when to escalate to Hermes for agentic work.
Speech-to-text uses Foundry fast transcription; text-to-speech uses fish.audio.
Serves a browser face UI and a WebSocket protocol on one port.
"""

import asyncio
import contextlib
import json
import logging
import os
import random
import re
import time
from pathlib import Path

from aiohttp import ClientSession, ClientTimeout, FormData, WSMsgType, web

from personas import EMOTIONS, PERSONAS

log = logging.getLogger("voice")

FOUNDRY_ENDPOINT = os.environ.get("FOUNDRY_ENDPOINT", "").rstrip("/")
CHAT_DEPLOYMENT = os.environ.get("VOICE_CHAT_DEPLOYMENT", "gpt-4.1-mini")
CHAT_API_VERSION = os.environ.get("VOICE_CHAT_API_VERSION", "2025-01-01-preview")
STT_API_VERSION = os.environ.get("VOICE_STT_API_VERSION", "2024-11-15")
STT_LOCALE = os.environ.get("STT_LOCALE", "en-US")
FISH_API_KEY = os.environ.get("FISH_API_KEY", "")
FISH_MODEL = os.environ.get("FISH_MODEL", "s1")
FISH_URL = os.environ.get("FISH_URL", "https://api.fish.audio/v1/tts")
HERMES_URL = os.environ.get("HERMES_URL", "http://127.0.0.1:8642").rstrip("/")
HERMES_API_KEY = os.environ.get("HERMES_API_KEY", "")
HERMES_TIMEOUT = float(os.environ.get("HERMES_TIMEOUT", "120"))
HERMES_FILLER_AFTER = float(os.environ.get("HERMES_FILLER_AFTER", "8"))
HERMES_REASONING_EFFORT = os.environ.get("HERMES_REASONING_EFFORT", "")
PORT = int(os.environ.get("PORT", "8765"))
HISTORY_MAX = 8
MAX_TEXT_CHARS = 2000
MAX_AUDIO_BYTES = 4 * 1024 * 1024
COGNITIVE_SCOPE = "https://cognitiveservices.azure.com"
STATIC_DIR = Path(__file__).parent / "static"

TAG_RE = re.compile(r"^\s*\[(\w+)\]\s*")
SENTENCE_RE = re.compile(r"(?<=[!?])\s+|(?<=[^.]\.)\s+")
MARKDOWN_RE = re.compile(r"[*_#`>]+")


class TokenProvider:
    """Entra token for Foundry: managed identity in Azure, az CLI locally."""

    def __init__(self, http: ClientSession):
        self._http = http
        self._token = ""
        self._expires = 0.0
        self._lock = asyncio.Lock()

    async def get(self) -> str:
        async with self._lock:
            if time.time() < self._expires - 300:
                return self._token
            if os.environ.get("IDENTITY_ENDPOINT"):
                token, expires = await self._from_managed_identity()
            else:
                token, expires = await self._from_az_cli()
            self._token, self._expires = token, expires
            return token

    async def _from_managed_identity(self):
        params = {"api-version": "2019-08-01", "resource": COGNITIVE_SCOPE}
        if os.environ.get("AZURE_CLIENT_ID"):
            params["client_id"] = os.environ["AZURE_CLIENT_ID"]
        headers = {"X-IDENTITY-HEADER": os.environ.get("IDENTITY_HEADER", "")}
        async with self._http.get(os.environ["IDENTITY_ENDPOINT"], params=params,
                                  headers=headers) as r:
            r.raise_for_status()
            data = await r.json(content_type=None)
        return data["access_token"], float(data["expires_on"])

    async def _from_az_cli(self):
        proc = await asyncio.create_subprocess_exec(
            "az", "account", "get-access-token", "--resource", COGNITIVE_SCOPE, "-o", "json",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, err = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError("az get-access-token failed: " + err.decode()[:200])
        data = json.loads(out)
        return data["accessToken"], float(data.get("expires_on") or time.time() + 3000)


def clean_for_speech(text: str) -> str:
    text = MARKDOWN_RE.sub("", text)
    return " ".join(text.split())


class SentenceSplitter:
    def __init__(self):
        self.buf = ""

    def feed(self, text: str) -> list[str]:
        self.buf += text
        parts = SENTENCE_RE.split(self.buf)
        self.buf = parts.pop()
        return [p.strip() for p in parts if p.strip()]

    def flush(self) -> list[str]:
        rest, self.buf = self.buf.strip(), ""
        return [rest] if rest else []


async def iter_sse(resp):
    """Yield decoded JSON payloads from an SSE response."""
    async for raw in resp.content:
        line = raw.decode(errors="replace").strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload == "[DONE]":
            return
        try:
            yield json.loads(payload)
        except json.JSONDecodeError:
            continue


class Services:
    def __init__(self, http: ClientSession):
        self.http = http
        self.tokens = TokenProvider(http)

    async def transcribe(self, wav: bytes) -> str:
        url = (f"{FOUNDRY_ENDPOINT}/speechtotext/transcriptions:transcribe"
               f"?api-version={STT_API_VERSION}")
        form = FormData()
        form.add_field("audio", wav, filename="audio.wav", content_type="audio/wav")
        form.add_field("definition", json.dumps({"locales": [STT_LOCALE]}),
                       content_type="application/json")
        headers = {"Authorization": "Bearer " + await self.tokens.get()}
        async with self.http.post(url, data=form, headers=headers,
                                  timeout=ClientTimeout(total=30)) as r:
            if r.status >= 400:
                raise RuntimeError(f"STT HTTP {r.status}: {(await r.text())[:200]}")
            data = await r.json(content_type=None)
        phrases = data.get("combinedPhrases") or []
        return (phrases[0].get("text", "") if phrases else "").strip()

    async def chat_stream(self, messages: list[dict]):
        url = (f"{FOUNDRY_ENDPOINT}/openai/deployments/{CHAT_DEPLOYMENT}/chat/completions"
               f"?api-version={CHAT_API_VERSION}")
        body = {"messages": messages, "stream": True, "max_tokens": 200, "temperature": 0.8}
        headers = {"Authorization": "Bearer " + await self.tokens.get()}
        async with self.http.post(url, json=body, headers=headers,
                                  timeout=ClientTimeout(total=30, sock_read=15)) as r:
            if r.status >= 400:
                raise RuntimeError(f"chat HTTP {r.status}: {(await r.text())[:200]}")
            async for evt in iter_sse(r):
                for choice in evt.get("choices") or []:
                    delta = (choice.get("delta") or {}).get("content")
                    if delta:
                        yield delta

    async def hermes_stream(self, text: str, instructions: str):
        body = {"model": "hermes", "input": text, "instructions": instructions,
                "stream": True}
        if HERMES_REASONING_EFFORT:
            body["model_options"] = {"reasoning_effort": HERMES_REASONING_EFFORT}
        headers = {"Authorization": "Bearer " + HERMES_API_KEY,
                   "Accept": "text/event-stream"}
        async with self.http.post(f"{HERMES_URL}/v1/responses", json=body, headers=headers,
                                  timeout=ClientTimeout(total=HERMES_TIMEOUT)) as r:
            if r.status >= 400:
                raise RuntimeError(f"hermes HTTP {r.status}: {(await r.text())[:200]}")
            async for evt in iter_sse(r):
                etype = evt.get("type")
                if etype == "response.output_text.delta":
                    yield evt.get("delta", "")
                elif etype == "response.failed":
                    raise RuntimeError("hermes response failed")
                elif etype == "response.completed":
                    return

    async def tts(self, text: str, voice_id: str) -> bytes:
        body = {"text": text, "reference_id": voice_id, "format": "mp3",
                "latency": "balanced"}
        headers = {"Authorization": "Bearer " + FISH_API_KEY, "model": FISH_MODEL}
        async with self.http.post(FISH_URL, json=body, headers=headers,
                                  timeout=ClientTimeout(total=30)) as r:
            if r.status >= 400:
                raise RuntimeError(f"TTS HTTP {r.status}: {(await r.text())[:200]}")
            return await r.read()


class Speaker:
    """Starts TTS for each sentence immediately, delivers audio in order."""

    def __init__(self, conn: "Connection", t0: float):
        self.conn = conn
        self.t0 = t0
        self.queue: asyncio.Queue = asyncio.Queue()
        self.first_audio = None
        self.index = 0
        self.spoken: list[str] = []
        self.task = asyncio.create_task(self._run())

    def say(self, sentence: str):
        sentence = clean_for_speech(sentence)
        if not sentence:
            return
        self.spoken.append(sentence)
        fetch = asyncio.create_task(self.conn.svc.tts(sentence, self.conn.voice_id))
        self.queue.put_nowait((sentence, fetch))

    async def close(self):
        self.queue.put_nowait(None)
        await self.task

    def cancel(self):
        self.task.cancel()
        while not self.queue.empty():
            item = self.queue.get_nowait()
            if item:
                item[1].cancel()

    async def _run(self):
        while (item := await self.queue.get()) is not None:
            sentence, fetch = item
            try:
                audio = await fetch
            except Exception as e:  # keep going; the text still shows in the transcript
                log.warning("tts failed: %s", e)
                await self.conn.send({"type": "error", "message": "tts failed"})
                continue
            if self.first_audio is None:
                self.first_audio = time.perf_counter() - self.t0
                await self.conn.send({"type": "state", "state": "speaking"})
            await self.conn.send({"type": "speak_begin", "text": sentence,
                                  "index": self.index})
            await self.conn.ws.send_bytes(audio)
            self.index += 1


class Connection:
    def __init__(self, ws: web.WebSocketResponse, svc: Services):
        self.ws = ws
        self.svc = svc
        self.persona_key = "rocky"
        self.history: list[dict] = []
        self.turn: asyncio.Task | None = None

    @property
    def persona(self) -> dict:
        return PERSONAS[self.persona_key]

    @property
    def voice_id(self) -> str:
        p = self.persona
        return os.environ.get(p["voice_env"]) or p["voice_default"]

    async def send(self, msg: dict):
        if not self.ws.closed:
            await self.ws.send_str(json.dumps(msg))

    def set_persona(self, key: str) -> bool:
        if key not in PERSONAS or key == self.persona_key:
            return False
        self.cancel_turn()
        self.persona_key = key
        self.history = []
        return True

    def greet(self):
        self.cancel_turn()
        self.turn = asyncio.create_task(self._greet())

    async def _greet(self):
        speaker = Speaker(self, time.perf_counter())
        try:
            await self.send({"type": "emotion", "emotion": "happy"})
            line = self.persona["greeting"]
            await self.send({"type": "transcript", "role": "assistant", "text": line})
            speaker.say(line)
            await speaker.close()
        except asyncio.CancelledError:
            speaker.cancel()
            raise
        except Exception as e:
            log.warning("greeting failed: %s", e)
        await self.send({"type": "state", "state": "done"})

    def cancel_turn(self):
        if self.turn and not self.turn.done():
            self.turn.cancel()

    def start_turn(self, *, audio: bytes | None = None, text: str | None = None):
        self.cancel_turn()
        self.turn = asyncio.create_task(self._turn(audio=audio, text=text))

    async def _turn(self, *, audio, text):
        t0 = time.perf_counter()
        metrics = {"route": "fast"}
        speaker = None
        cancelled = False
        try:
            await self.send({"type": "state", "state": "thinking"})
            await self.send({"type": "emotion", "emotion": "thinking"})
            if audio is not None:
                text = await self.svc.transcribe(audio)
                metrics["stt"] = round(time.perf_counter() - t0, 3)
            text = (text or "").strip()[:MAX_TEXT_CHARS]
            if not text:
                await self.send({"type": "emotion", "emotion": "neutral"})
                return
            await self.send({"type": "transcript", "role": "user", "text": text})

            speaker = Speaker(self, t0)
            messages = ([{"role": "system", "content": self.persona["system"]}]
                        + self.history + [{"role": "user", "content": text}])
            reply, route = await self._fast_reply(messages, speaker, metrics, t0)
            if route == "hermes":
                metrics["route"] = "hermes"
                reply = await self._hermes_reply(text, speaker, metrics, t0)

            await speaker.close()
            metrics["ttfa"] = round(speaker.first_audio, 3) if speaker.first_audio else None
            self.history += [{"role": "user", "content": text},
                             {"role": "assistant", "content": reply}]
            self.history = self.history[-HISTORY_MAX:]
            await self.send({"type": "transcript", "role": "assistant", "text": reply})
        except asyncio.CancelledError:
            cancelled = True
            if speaker:
                speaker.cancel()
            raise
        except Exception as e:
            log.exception("turn failed")
            if speaker:
                speaker.cancel()
            await self.send({"type": "error", "message": str(e)[:300]})
            await self.send({"type": "emotion", "emotion": "sad"})
            try:
                err = Speaker(self, t0)
                err.say(self.persona["error_line"])
                await err.close()
            except Exception:
                pass
        finally:
            # A superseding turn/cancel owns the "done" signal; don't race it.
            if not cancelled:
                metrics["total"] = round(time.perf_counter() - t0, 3)
                await self.send({"type": "metrics", **metrics})
                await self.send({"type": "state", "state": "done"})

    async def _fast_reply(self, messages, speaker: Speaker, metrics, t0):
        """Stream the fast model; return (spoken text, route)."""
        splitter = SentenceSplitter()
        head, tag_done, route, body = "", False, "fast", ""
        async with contextlib.aclosing(self.svc.chat_stream(messages)) as stream:
            async for delta in stream:
                if "ttft" not in metrics:
                    metrics["ttft"] = round(time.perf_counter() - t0, 3)
                if not tag_done:
                    head += delta
                    if "]" not in head and len(head) < 24:
                        continue
                    tag_done = True
                    m = TAG_RE.match(head)
                    tag = m.group(1).lower() if m else "neutral"
                    delta = head[m.end():] if m else head
                    if tag == "hermes":
                        route = "hermes"
                        await self.send({"type": "emotion", "emotion": "thinking"})
                    else:
                        await self.send({"type": "emotion",
                                         "emotion": tag if tag in EMOTIONS else "neutral"})
                body += delta
                for s in splitter.feed(delta):
                    speaker.say(s)
                    if route == "hermes":  # speak only the acknowledgement sentence
                        return body.strip(), route
        if not tag_done:
            body = TAG_RE.sub("", head, count=1)
            for s in splitter.feed(body):
                speaker.say(s)
            await self.send({"type": "emotion", "emotion": "neutral"})
        for s in splitter.flush():
            speaker.say(s)
        if route == "hermes" and not body.strip():
            speaker.say(self.persona["fillers"][0])
        return clean_for_speech(body), route

    async def _hermes_reply(self, text, speaker: Speaker, metrics, t0) -> str:
        context = "\n".join(f"{m['role']}: {m['content']}" for m in self.history[-4:])
        prompt = (f"Recent voice conversation:\n{context}\n\nUser now says: {text}"
                  if context else text)
        fillers = list(self.persona["fillers"])
        random.shuffle(fillers)
        splitter = SentenceSplitter()
        chunks: list[str] = []
        got_text = asyncio.Event()

        async def filler_loop():
            for line in fillers:
                try:
                    await asyncio.wait_for(got_text.wait(), HERMES_FILLER_AFTER)
                    return
                except asyncio.TimeoutError:
                    speaker.say(line)

        filler_task = asyncio.create_task(filler_loop())
        h0 = time.perf_counter()
        try:
            first = True
            async for delta in self.svc.hermes_stream(prompt, self.persona["hermes_brief"]):
                if not delta:
                    continue
                if first:
                    first = False
                    got_text.set()
                    metrics["hermes_ttft"] = round(time.perf_counter() - h0, 3)
                    delta = TAG_RE.sub("", delta, count=1)
                    await self.send({"type": "emotion", "emotion": "neutral"})
                chunks.append(delta)
                for s in splitter.feed(delta):
                    speaker.say(s)
            for s in splitter.flush():
                speaker.say(s)
        finally:
            got_text.set()
            filler_task.cancel()
        return clean_for_speech("".join(chunks))


@web.middleware
async def security_headers(request, handler):
    resp = await handler(request)
    resp.headers.setdefault("X-Content-Type-Options", "nosniff")
    resp.headers.setdefault("X-Frame-Options", "DENY")
    resp.headers.setdefault("Referrer-Policy", "no-referrer")
    resp.headers.setdefault(
        "Content-Security-Policy",
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        "connect-src 'self'; media-src 'self' blob:; worker-src 'self' blob:; "
        "frame-ancestors 'none'; base-uri 'self'; form-action 'none'")
    resp.headers.setdefault("Permissions-Policy", "microphone=(self), camera=(), geolocation=()")
    return resp


async def ws_handler(request: web.Request):
    ws = web.WebSocketResponse(max_msg_size=MAX_AUDIO_BYTES, heartbeat=30)
    await ws.prepare(request)
    conn = Connection(ws, request.app["svc"])
    try:
        async for msg in ws:
            if msg.type == WSMsgType.BINARY:
                conn.start_turn(audio=msg.data)
            elif msg.type == WSMsgType.TEXT:
                try:
                    data = json.loads(msg.data)
                except json.JSONDecodeError:
                    continue
                kind = data.get("type")
                if kind in ("hello", "persona"):
                    key = str(data.get("persona", "")).lower()
                    changed = conn.set_persona(key)
                    await conn.send({"type": "persona", "persona": conn.persona_key,
                                     "name": conn.persona["name"]})
                    if changed or data.get("greet"):
                        conn.greet()
                elif kind == "text":
                    conn.start_turn(text=str(data.get("text", "")))
                elif kind == "cancel":
                    conn.cancel_turn()
                    await conn.send({"type": "state", "state": "done"})
    finally:
        conn.cancel_turn()
    return ws


async def healthz(_request):
    return web.json_response({"ok": True, "personas": list(PERSONAS),
                              "chat": CHAT_DEPLOYMENT})


async def index(_request):
    return web.FileResponse(STATIC_DIR / "index.html",
                            headers={"Cache-Control": "no-cache"})


async def on_startup(app):
    app["http"] = ClientSession()
    app["svc"] = Services(app["http"])
    missing = [n for n, v in (("FOUNDRY_ENDPOINT", FOUNDRY_ENDPOINT),
                              ("FISH_API_KEY", FISH_API_KEY),
                              ("HERMES_API_KEY", HERMES_API_KEY)) if not v]
    if missing:
        log.warning("missing configuration: %s", ", ".join(missing))
    try:
        await app["svc"].tokens.get()
    except Exception as e:
        log.warning("token warm-up failed: %s", e)


async def on_cleanup(app):
    await app["http"].close()


def make_app() -> web.Application:
    app = web.Application(middlewares=[security_headers])
    app.router.add_get("/", index)
    app.router.add_get("/healthz", healthz)
    app.router.add_get("/ws", ws_handler)
    app.router.add_static("/static/", STATIC_DIR)
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    return app


if __name__ == "__main__":
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    web.run_app(make_app(), host=os.environ.get("HOST", "127.0.0.1"), port=PORT)
