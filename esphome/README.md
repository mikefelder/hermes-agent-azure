# Voice PE → Hermes voice sidecar (ON HOLD)

Plan and status for driving a **Home Assistant Voice Preview Edition** (Nabu Casa)
directly from the Hermes voice sidecar (`voice/server.py`) — **no Home Assistant**
("Option B"). The device speaks the ESPHome native API; the sidecar acts as the
voice-assistant server that HA would normally be.

```
Voice PE ──(ESPHome API :6053, noise-encrypted)──► voice/voicepe_bridge.py
   ▲  wake word "Okay Nabu" on-device                │ 16 kHz PCM → WAV → Foundry STT
   │                                                 │ persona reply (Foundry / Hermes)
   └──── HTTP GET chunked MP3 ◄── /pe/audio/{token}.mp3 ◄─ fish.audio TTS
```

## Status (paused)

| Item | State |
|---|---|
| Device on Wi-Fi | ✅ `192.168.0.169` (stock firmware) |
| `esphome/voice-pe.yaml` | ✅ name `hermes-voice`, package `home-assistant-voice-pe@26.9.0` |
| `esphome/secrets.yaml` | ✅ `wifi_ssid`, `wifi_password`, `api_encryption_key` (gitignored, chmod 600) |
| Firmware compile | ✅ `esphome/.esphome/build/hermes-voice/build/firmware.ota.bin` |
| OTA flash | ⬜ not yet |
| `aioesphomeapi` in `voice/requirements.txt` | ⬜ (installed in `voice/.venv` only: 46.4.1) |
| `voice/voicepe_bridge.py` | ⬜ not written |
| `server.py` wiring + `.env` | ⬜ |
| End-to-end test | ⬜ |

## Build / flash (Docker, macOS)

`files.pythonhosted.org` is blocked on this network, so point uv/pip at the proxy.
Run from the repo root.

```bash
P=https://packagefeedproxy.microsoft.io/pypi/simple/
DOCKER_FLAGS=(--rm -e UV_INDEX_URL=$P -e UV_DEFAULT_INDEX=$P -e PIP_INDEX_URL=$P
  -e UV_HTTP_TIMEOUT=120 -v "$PWD/esphome":/config -v "$PWD/esphome/.cache":/cache)

# compile
docker run "${DOCKER_FLAGS[@]}" esphome/esphome compile voice-pe.yaml
# flash over the air (Docker Desktop on macOS has no USB passthrough)
docker run "${DOCKER_FLAGS[@]}" esphome/esphome run voice-pe.yaml --device 192.168.0.169
```

After flashing, the device advertises as `hermes-voice.local:6053`.
If OTA to stock firmware is refused, use the web flasher / USB from the host instead.

## Bridge design (`voice/voicepe_bridge.py`)

- `APIClient(host, 6053, noise_psk=VOICE_PE_KEY, client_info="hermes-voice", expected_name="hermes-voice")`
  wrapped in `ReconnectLogic` (`aioesphomeapi.reconnect_logic`).
- `subscribe_voice_assistant(handle_start=, handle_stop=, handle_audio=)`:
  - `handle_start(conversation_id, flags, audio_settings, wake_word_phrase)` → async, return `0`
    (0 = audio over the API, not UDP).
  - `handle_audio(data, data2)` → 16 kHz / 16-bit / mono PCM; buffer it.
  - `handle_stop(abort)` → async.
- Server-side energy VAD: end the utterance after ~0.8 s silence (hard cap ~8 s), then wrap
  PCM in a WAV header and send through the existing STT path.
- Reuse the persona pipeline by handing it a **fake ws object** per device:
  - `send_str` → capture transcript / reply text and the `state:done` signal.
  - `send_bytes` → push MP3 chunks onto an `asyncio.Queue`.
- New route `/pe/audio/{token}.mp3` → chunked `audio/mpeg` `StreamResponse` draining that queue;
  the device fetches it from `VOICE_PE_PUBLIC_URL`.
- Start in `on_startup`, stop in `on_cleanup` (`voice/server.py`).

### Events to send (`send_voice_assistant_event`)

Enum values: ERROR=0, RUN_START=1, RUN_END=2, STT_START=3, STT_END=4, INTENT_START=5,
INTENT_END=6, TTS_START=7, TTS_END=8, STT_VAD_END=12, INTENT_PROGRESS=100.

1. `RUN_START {"url": <mp3 url>}` → `STT_START`
2. VAD end → `STT_VAD_END` → `STT_END {"text": transcript}` → `INTENT_START`
3. first MP3 chunk → `INTENT_PROGRESS {"tts_start_streaming": "1"}` (device starts playback early)
4. done → `INTENT_END {"conversation_id": ...}` → `TTS_START {"text": reply}` →
   `TTS_END {"url": <mp3 url>}` → `RUN_END`
5. failure → `ERROR {"code", "message"}` → `RUN_END`

### Env (`voice/.env`, gitignored)

```bash
HOST=0.0.0.0                                   # device must reach the sidecar over LAN
VOICE_PE_HOST=hermes-voice.local               # or 192.168.0.169
VOICE_PE_KEY=<api_encryption_key from esphome/secrets.yaml>
VOICE_PE_PUBLIC_URL=http://<mac-lan-ip>:8765
VOICE_PE_PERSONA=rocky                          # or tars
```

`server.py` doesn't load dotenv: `set -a; . voice/.env; set +a` before starting.

## Resume checklist

1. Add `aioesphomeapi==46.4.1` to `voice/requirements.txt`.
2. Write `voice/voicepe_bridge.py` (above) and wire it into `voice/server.py`; skip cleanly when `VOICE_PE_HOST` is unset.
3. OTA flash (command above).
4. Create `voice/.env`, restart the sidecar, and allow the macOS firewall prompt for Python.
5. Say "Okay Nabu" and check the transcript, the reply and the speaker audio. Check the latency against the browser UI.
6. Commit. Never commit `secrets.yaml`, `.env`, `.esphome/` or `.cache/`.

Later: a custom wake word ("Hey Rocky") via microWakeWord, persona switching by button or
second wake word, and LED ring states tied to the event stream.
