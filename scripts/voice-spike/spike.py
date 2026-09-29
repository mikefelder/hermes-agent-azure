# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Phase 0 latency spike: Hermes time-to-first-sentence + fish.audio time-to-first-byte.

Usage:
  export HERMES_API_KEY=...   # API_SERVER_KEY from the container
  export FISH_API_KEY=...
  python3 scripts/voice-spike/spike.py [--runs 3] [--skip-hermes] [--skip-tts]

Stdlib only (no PyPI access needed).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
import time
import urllib.error
import urllib.request

HERMES_URL = os.environ.get("HERMES_URL", "https://hermes.taile1e16.ts.net:8443")
FISH_URL = "https://api.fish.audio/v1/tts"
FISH_MODEL = os.environ.get("FISH_MODEL", "s1")
SENTENCE_END = re.compile(r"[.!?](\s|$)")

PROFILES = {
    "rocky": {
        "voice_id": "6dd07916890445e59c5f019ad0fc7879",
        "instructions": (
            "You are Rocky, the Eridian engineer from Project Hail Mary. Speak in short, "
            "clipped sentences. Drop articles. End questions with the word 'question'. "
            "Show enthusiasm with 'Amaze!' when appropriate. Keep replies to 1-3 sentences; "
            "this will be spoken aloud."
        ),
        "prompt": "Hey Rocky, what's a good way to keep a sourdough starter alive?",
        "sample": "Amaze! Starter is small colony. Feed flour and water every day, keep warm. You do this, question?",
    },
    "tars": {
        "voice_id": "6a57e35f5c8244dbb5d012a3c434ec16",
        "instructions": (
            "You are TARS, the robot from Interstellar. Deadpan, dry humor, precise. "
            "Occasionally reference your humor or honesty setting as a percentage. "
            "Keep replies to 1-3 sentences; this will be spoken aloud."
        ),
        "prompt": "TARS, what's a good way to keep a sourdough starter alive?",
        "sample": "Feed it flour and water daily and keep it warm. Humor setting at seventy-five percent: it has better survival odds than most crew members.",
    },
}


def _post(url: str, headers: dict, body: dict, timeout: float):
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", **headers},
        method="POST",
    )
    try:
        return urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        raise RuntimeError(f"{url} HTTP {e.code}: {detail}") from None


def hermes_run(key: str, profile: dict, opts: argparse.Namespace) -> dict:
    body = {
        "model": opts.model or "hermes",
        "input": profile["prompt"],
        "instructions": profile["instructions"],
        "stream": True,
    }
    if opts.provider:
        body["provider"] = opts.provider
    model_options = {}
    if opts.reasoning_effort:
        model_options["reasoning_effort"] = opts.reasoning_effort
    if opts.fast:
        model_options["service_tier"] = "priority"
    if model_options:
        body["model_options"] = model_options
    t0 = time.perf_counter()
    ttft = ttfs = first_evt = None
    text = ""
    headers = {"Authorization": "Bearer " + key, "Accept": "text/event-stream"}
    with _post(f"{HERMES_URL}/v1/responses", headers, body, timeout=120) as r:
        for raw in r:
            line = raw.decode(errors="replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                evt = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if first_evt is None:
                first_evt = time.perf_counter() - t0
            etype = evt.get("type")
            if etype == "response.output_text.delta":
                now = time.perf_counter() - t0
                if ttft is None:
                    ttft = now
                text += evt.get("delta", "")
                if ttfs is None and SENTENCE_END.search(text):
                    ttfs = now
            elif etype in ("response.completed", "response.failed"):
                break
    total = time.perf_counter() - t0
    return {"first_evt": first_evt, "ttft": ttft, "ttfs": ttfs or total, "total": total,
            "text": text.strip()}


def fish_run(key: str, profile: dict, text: str) -> dict:
    body = {
        "text": text,
        "reference_id": profile["voice_id"],
        "format": "mp3",
        "latency": "balanced",
    }
    t0 = time.perf_counter()
    ttfb = None
    nbytes = 0
    headers = {"Authorization": "Bearer " + key, "model": FISH_MODEL}
    with _post(FISH_URL, headers, body, timeout=60) as r:
        while True:
            chunk = r.read1(8192)
            if not chunk:
                break
            if ttfb is None:
                ttfb = time.perf_counter() - t0
            nbytes += len(chunk)
    return {"ttfb": ttfb, "total": time.perf_counter() - t0, "bytes": nbytes}


def med(values: list[float | None]) -> str:
    v = [x for x in values if x is not None]
    return f"{statistics.median(v):.2f}s" if v else "n/a"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--skip-hermes", action="store_true")
    ap.add_argument("--skip-tts", action="store_true")
    ap.add_argument("--reasoning-effort",
                    choices=["none", "minimal", "low", "medium", "high", "xhigh"],
                    help="sent as model_options.reasoning_effort")
    ap.add_argument("--fast", action="store_true",
                    help="sent as model_options.service_tier=priority")
    ap.add_argument("--model", help="override model (needs --provider or direct_model_requests)")
    ap.add_argument("--provider", help="override provider, e.g. azure-foundry")
    ap.add_argument("--persona", choices=["rocky", "tars"], help="only run one persona")
    args = ap.parse_args()

    hermes_key = os.environ.get("HERMES_API_KEY")
    fish_key = os.environ.get("FISH_API_KEY")
    if not args.skip_hermes and not hermes_key:
        print("HERMES_API_KEY not set (or pass --skip-hermes)", file=sys.stderr)
        return 2
    if not args.skip_tts and not fish_key:
        print("FISH_API_KEY not set (or pass --skip-tts)", file=sys.stderr)
        return 2

    for name, profile in PROFILES.items():
        if args.persona and name != args.persona:
            continue
        print(f"\n=== {name.upper()} ===")
        h_results, f_results = [], []
        for i in range(args.runs):
            first_sentence = profile["sample"]
            if not args.skip_hermes:
                h = hermes_run(hermes_key, profile, args)
                h_results.append(h)
                print(f"  hermes run {i+1}: first_evt={h['first_evt'] and round(h['first_evt'],2)}s "
                      f"ttft={h['ttft'] and round(h['ttft'],2)}s "
                      f"ttfs={h['ttfs']:.2f}s total={h['total']:.2f}s")
                print(f"    -> {h['text'][:160]!r}")
                m = SENTENCE_END.search(h["text"])
                if h["text"]:
                    first_sentence = h["text"][: m.end()].strip() if m else h["text"]
            if not args.skip_tts:
                f = fish_run(fish_key, profile, first_sentence)
                f_results.append(f)
                print(f"  fish  run {i+1}: ttfb={f['ttfb'] and round(f['ttfb'],2)}s "
                      f"total={f['total']:.2f}s bytes={f['bytes']}")

        print(f"  --- medians ({args.runs} runs) ---")
        if h_results:
            print(f"  hermes first_evt={med([r['first_evt'] for r in h_results])} "
                  f"ttft={med([r['ttft'] for r in h_results])} "
                  f"ttfs={med([r['ttfs'] for r in h_results])} total={med([r['total'] for r in h_results])}")
        if f_results:
            print(f"  fish   ttfb={med([r['ttfb'] for r in f_results])} total={med([r['total'] for r in f_results])}")
        if h_results and f_results:
            ttfs = statistics.median(r["ttfs"] for r in h_results)
            ttfb = statistics.median(r["ttfb"] or r["total"] for r in f_results)
            print(f"  est. time-to-first-audio (excl. STT): {ttfs + ttfb:.2f}s  "
                  f"(+0.3-0.5s STT => {ttfs + ttfb + 0.3:.2f}-{ttfs + ttfb + 0.5:.2f}s)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.URLError as e:
        reason = getattr(e, "reason", e)
        print(f"\nnetwork error: {reason}", file=sys.stderr)
        if "nodename" in str(reason) or "Name or service" in str(reason):
            print("hint: hostname didn't resolve - is Tailscale connected with MagicDNS on? "
                  "(or set HERMES_URL)", file=sys.stderr)
        sys.exit(1)
    except (TimeoutError, RuntimeError) as e:
        print(f"\nerror: {e}", file=sys.stderr)
        sys.exit(1)
