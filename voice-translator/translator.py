"""
Voice-Chat-Übersetzer (Prototyp, Windows)

Ablauf:
  Ton aufnehmen (Lautsprecher-Loopback oder Mikrofon)
  -> bei Sprechpause ein Stück abschneiden
  -> Speech-to-Text über Groq oder OpenAI (Sprache wird automatisch erkannt)
  -> DeepL übersetzt in die Zielsprache
  -> Text im Fenster + Windows-Sprachausgabe

Start:  python translator.py
Hilfen: python translator.py --geraete   (Audiogeräte auflisten)
        python translator.py --pegel     (Lautstärke live anzeigen, zum Einstellen)
"""

import io
import json
import os
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
import warnings
import wave
from collections import deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import numpy as np

# Aufnahme-Samplerate: 48 kHz ist die native Rate der meisten Windows-Geräte.
# Für die Spracherkennung wird danach auf 16 kHz verkleinert (spart Upload).
RECORD_RATE = 48000
STT_RATE = 16000
BLOCK_SECONDS = 0.1

# Typische "Halluzinationen" der Spracherkennung bei Rauschen/Stille.
# Solche Ergebnisse werden verworfen statt übersetzt.
HALLUCINATIONS = {
    "thank you.", "thanks for watching!", "thank you for watching.",
    "untertitel der amara.org-community", "untertitel im auftrag des zdf, 2017",
    "untertitelung des zdf, 2020", "vielen dank.", "you", ".", "...",
}


def app_dir():
    """Ordner der .exe bzw. des Skripts - dort liegt die .env mit den Keys."""
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def resource_path(name):
    """Mitgelieferte Dateien (phone.html); in der .exe liegen sie in einem Temp-Ordner."""
    return os.path.join(getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__))), name)


def env_path():
    return os.path.join(app_dir(), ".env")


# Anbieter für Speech-to-Text. Beide sprechen dieselbe (OpenAI-)Schnittstelle,
# Groq braucht nur eine andere Adresse und hat ein Gratis-Kontingent.
STT_PROVIDERS = {
    "groq": {"name": "Groq", "key": "groq_key",
             "base_url": "https://api.groq.com/openai/v1", "model": "whisper-large-v3-turbo"},
    "openai": {"name": "OpenAI", "key": "openai_key",
               "base_url": None, "model": "whisper-1"},
}

# Reihenfolge und Namen der Einträge in .env
ENV_NAMES = {
    "stt_provider": "STT_PROVIDER", "groq_key": "GROQ_API_KEY",
    "openai_key": "OPENAI_API_KEY", "deepl_key": "DEEPL_API_KEY",
    "target_lang": "TARGET_LANG", "source": "AUDIO_SOURCE", "device": "AUDIO_DEVICE",
    "speak": "SPEAK", "tts_rate": "TTS_RATE", "threshold": "VOLUME_THRESHOLD",
    "silence": "SILENCE_SECONDS", "min_speech": "MIN_SPEECH_SECONDS",
    "max_speech": "MAX_SPEECH_SECONDS", "stt_model": "STT_MODEL",
    "phone_view": "PHONE_VIEW", "phone_port": "PHONE_PORT",
    "in_enabled": "IN_ENABLED", "out_enabled": "OUT_ENABLED",
    "out_device": "OUT_MIC_DEVICE", "out_target": "OUT_TARGET_LANG",
    "out_output": "OUT_OUTPUT_DEVICE", "out_threshold": "OUT_VOLUME_THRESHOLD",
}


def load_config():
    values = {}
    try:
        from dotenv import dotenv_values
        if os.path.exists(env_path()):
            values = dotenv_values(env_path())
    except ImportError:
        pass

    def getenv(name, default=""):
        value = values.get(name)
        return value if value is not None else os.getenv(name, default)

    def num(name, default):
        try:
            return float(getenv(name, default))
        except ValueError:
            print(f"Warnung: {name} in .env ist keine Zahl, nehme {default}.")
            return float(default)

    provider = getenv("STT_PROVIDER", "groq").strip().lower()
    if provider not in STT_PROVIDERS:
        print(f"Warnung: STT_PROVIDER '{provider}' unbekannt, nehme groq.")
        provider = "groq"

    return {
        "stt_provider": provider,
        "groq_key": getenv("GROQ_API_KEY", "").strip(),
        "openai_key": getenv("OPENAI_API_KEY", "").strip(),
        "deepl_key": getenv("DEEPL_API_KEY", "").strip(),
        "target_lang": getenv("TARGET_LANG", "DE").strip().upper(),
        "source": getenv("AUDIO_SOURCE", "loopback").strip().lower(),
        "device": getenv("AUDIO_DEVICE", "").strip(),
        "speak": getenv("SPEAK", "1").strip() not in ("0", "nein", "no", "false"),
        "threshold": num("VOLUME_THRESHOLD", "0.01"),
        "silence": num("SILENCE_SECONDS", "0.8"),
        "min_speech": num("MIN_SPEECH_SECONDS", "0.5"),
        "max_speech": num("MAX_SPEECH_SECONDS", "15"),
        # Leer = Standardmodell des gewählten Anbieters
        "stt_model": getenv("STT_MODEL", "").strip(),
        "tts_rate": int(num("TTS_RATE", "1")),
        "phone_view": getenv("PHONE_VIEW", "1").strip() not in ("0", "nein", "no", "false"),
        "phone_port": int(num("PHONE_PORT", "8765")),
        # Gegenrichtung: eigenes Mikrofon -> Übersetzung -> VB-Cable -> Spiel/Discord
        "in_enabled": getenv("IN_ENABLED", "1").strip() not in ("0", "nein", "no", "false"),
        "out_enabled": getenv("OUT_ENABLED", "0").strip() not in ("0", "nein", "no", "false"),
        "out_device": getenv("OUT_MIC_DEVICE", "").strip(),
        "out_target": getenv("OUT_TARGET_LANG", "AUTO").strip().upper(),
        "out_output": getenv("OUT_OUTPUT_DEVICE", "CABLE Input").strip(),
        "out_threshold": num("OUT_VOLUME_THRESHOLD", "0.02"),
    }


def direction_config(cfg, direction):
    """Leitet aus den Einstellungen die Werte für eine Richtung ab.

    in:  Mitspieler (Lautsprecher/Loopback) -> ich, Ausgabe über Standard-Lautsprecher
    out: ich (Mikrofon) -> Mitspieler, Ausgabe über ein Gerät wie VB-Cable
    """
    if direction == "in":
        return dict(cfg, direction="in", output_device="")
    return dict(cfg, direction="out", source="mic", device=cfg["out_device"],
                target_lang=cfg["out_target"], threshold=cfg["out_threshold"],
                speak=True, phone_view=False, output_device=cfg["out_output"])


def save_config(cfg):
    lines = ["# Von der App gespeichert. Enthaelt deine API-Keys - nicht weitergeben!"]
    for key, name in ENV_NAMES.items():
        value = cfg[key]
        if isinstance(value, bool):
            value = "1" if value else "0"
        value = str(value).replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'{name}="{value}"')
    with open(env_path(), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


# ---------------------------------------------------------------- Audio

def find_input(source, device_filter, log=print):
    """Liefert das soundcard-Aufnahmegerät für Loopback oder Mikrofon."""
    import soundcard as sc

    wanted = device_filter.lower()
    if source == "mic":
        mics = sc.all_microphones()
        if wanted:
            for m in mics:
                if wanted in m.name.lower():
                    return m
            log(f"Kein Mikrofon mit '{device_filter}' im Namen gefunden, nehme Standard.")
        return sc.default_microphone()

    speaker = sc.default_speaker()
    if wanted:
        for s in sc.all_speakers():
            if wanted in s.name.lower():
                speaker = s
                break
        else:
            log(f"Kein Ausgabegerät mit '{device_filter}' im Namen gefunden, nehme Standard.")
    return sc.get_microphone(id=str(speaker.name), include_loopback=True)


def device_names(source):
    import soundcard as sc

    devices = sc.all_microphones() if source == "mic" else sc.all_speakers()
    return [d.name for d in devices]


def list_devices():
    import soundcard as sc

    print("Ausgabegeräte (für AUDIO_SOURCE=loopback):")
    for s in sc.all_speakers():
        print("   ", s.name)
    print("\nMikrofone (für AUDIO_SOURCE=mic):")
    for m in sc.all_microphones():
        print("   ", m.name)
    print("\nIn .env bei AUDIO_DEVICE einen eindeutigen Teil des Namens eintragen.")


def to_mono(block):
    return block.mean(axis=1) if block.ndim == 2 else block


def rms(block):
    return float(np.sqrt(np.mean(np.square(block)))) if len(block) else 0.0


class SpeechSegmenter:
    """Sammelt Audioblöcke und gibt ein Stück zurück, sobald eine Sprechpause kommt."""

    def __init__(self, threshold, silence_seconds, min_speech_seconds,
                 max_speech_seconds, block_seconds=BLOCK_SECONDS, preroll_seconds=0.3):
        self.threshold = threshold
        self.silence_blocks = max(1, round(silence_seconds / block_seconds))
        self.min_loud_blocks = max(1, round(min_speech_seconds / block_seconds))
        self.max_blocks = max(1, round(max_speech_seconds / block_seconds))
        self.preroll = deque(maxlen=max(1, round(preroll_seconds / block_seconds)))
        self.reset()

    def reset(self):
        self.active = False
        self.blocks = []
        self.silent_run = 0
        self.loud_blocks = 0

    def feed(self, block):
        loud = rms(block) >= self.threshold
        if not self.active:
            if loud:
                self.active = True
                self.blocks = list(self.preroll) + [block]
                self.preroll.clear()
                self.loud_blocks = 1
            else:
                self.preroll.append(block)
            return None

        self.blocks.append(block)
        if loud:
            self.loud_blocks += 1
            self.silent_run = 0
        else:
            self.silent_run += 1

        if self.silent_run >= self.silence_blocks or len(self.blocks) >= self.max_blocks:
            segment = np.concatenate(self.blocks)
            enough = self.loud_blocks >= self.min_loud_blocks
            self.reset()
            return segment if enough else None
        return None


def to_wav_bytes(samples, rate):
    if rate == 48000 and STT_RATE == 16000:
        usable = len(samples) - len(samples) % 3
        samples = samples[:usable].reshape(-1, 3).mean(axis=1)
        rate = STT_RATE
    pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())
    return buf.getvalue()


# ---------------------------------------------------------------- Handy-Anzeige

class PhoneView:
    """Kleiner Webserver im Heimnetz: das Handy zeigt die Übersetzungen im Browser an."""

    def __init__(self, port):
        self.port = port
        self.items = deque(maxlen=50)
        self.next_id = 1
        self.lock = threading.Lock()
        self.server = None
        with open(resource_path("phone.html"), "rb") as f:
            self.page = f.read()

    def add(self, source, original, translated, target):
        with self.lock:
            self.items.append({
                "id": self.next_id, "time": datetime.now().strftime("%H:%M:%S"),
                "source": source, "original": original,
                "translated": translated, "target": target,
            })
            self.next_id += 1

    def since(self, after):
        with self.lock:
            return [i for i in self.items if i["id"] > after]

    def start(self):
        view = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                url = urlparse(self.path)
                if url.path == "/api":
                    try:
                        after = int(parse_qs(url.query).get("after", ["0"])[0])
                    except ValueError:
                        after = 0
                    body, kind = json.dumps(view.since(after)).encode(), "application/json"
                elif url.path == "/":
                    body, kind = view.page, "text/html; charset=utf-8"
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", kind)
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass  # keine Zugriffs-Logs im Konsolenfenster

        self.server = ThreadingHTTPServer(("0.0.0.0", self.port), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return f"http://{lan_ip()}:{self.port}"

    def stop(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
            self.server = None


def lan_ip():
    # Verbindet nichts wirklich, fragt nur Windows, welche Netzwerkadresse ins Heimnetz zeigt.
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


# ---------------------------------------------------------------- Dienste

def deepl_target(lang):
    # DeepL verlangt bei Englisch/Portugiesisch als Ziel eine Variante.
    return {"EN": "EN-US", "PT": "PT-PT"}.get(lang, lang)


class SharedState:
    """Was beide Richtungen voneinander wissen müssen."""

    def __init__(self):
        # Zuletzt erkannte Sprache der Mitspieler: Ziel für "AUTO" in der Gegenrichtung.
        self.player_lang = None
        # Läuft gerade eine Ansage über die normalen Lautsprecher? Dann hört auch das
        # Mikrofon nicht zu, falls der Ton ohne Headset ins Mikrofon schallt.
        self.local_playback = threading.Event()
        self.local_until = 0.0

    def local_busy(self):
        return self.local_playback.is_set() or time.monotonic() < self.local_until


TTS_SCRIPT = (
    "Add-Type -AssemblyName System.Speech; "
    "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
    "$v = $s.GetInstalledVoices() | Where-Object "
    "{ $_.VoiceInfo.Culture.TwoLetterISOLanguageName -eq $env:VT_LANG } | Select-Object -First 1; "
    "if ($v) { $s.SelectVoice($v.VoiceInfo.Name) }; "
    "$s.Rate = [int]$env:VT_RATE; "
    "if ($env:VT_FILE) { "
    "$f = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(48000, "
    "[System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, "
    "[System.Speech.AudioFormat.AudioChannel]::Mono); "
    "$s.SetOutputToWaveFile($env:VT_FILE, $f) }; "
    "$s.Speak($env:VT_TEXT); $s.Dispose()"
)


def run_tts(text, lang, rate, wav_file=""):
    """Windows-Stimme: spricht direkt über den Standard-Lautsprecher oder in eine WAV-Datei."""
    # Text über Umgebungsvariable statt Kommandozeile: keine Probleme mit
    # Anführungszeichen oder Sonderzeichen im übersetzten Satz.
    env = dict(os.environ, VT_TEXT=text, VT_RATE=str(rate), VT_LANG=lang.lower(),
               VT_FILE=wav_file)
    subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", TTS_SCRIPT],
        env=env, timeout=60, creationflags=subprocess.CREATE_NO_WINDOW,
        # In der .exe ohne Konsole gibt es keine Standard-Ein/Ausgabe;
        # ohne diese Umleitung scheitert der Start von PowerShell.
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        check=True,
    )


def find_output(device_filter):
    import soundcard as sc

    wanted = device_filter.lower()
    for s in sc.all_speakers():
        if wanted in s.name.lower():
            return s
    raise RuntimeError(f"Ausgabegerät '{device_filter}' nicht gefunden. Ist VB-Cable installiert?")


def play_wav(path, device_filter):
    with wave.open(path, "rb") as w:
        rate, channels = w.getframerate(), w.getnchannels()
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    data = pcm.reshape(-1, channels).astype(np.float32) / 32768.0
    # Etwas Stille anhängen, damit das Satzende nicht abgeschnitten wird.
    data = np.concatenate([data, np.zeros((int(rate * 0.3), channels), dtype=np.float32)])
    find_output(device_filter).play(data, samplerate=rate)


class Pipeline:
    def __init__(self, cfg, log=print, shared=None):
        import deepl
        from openai import OpenAI

        self.cfg = cfg
        self.log = log
        self.shared = shared or SharedState()
        self.direction = cfg.get("direction", "in")
        self.output_device = cfg.get("output_device", "")
        stt = STT_PROVIDERS[cfg["stt_provider"]]
        self.stt_client = OpenAI(api_key=cfg[stt["key"]], base_url=stt["base_url"])
        self.stt_model = cfg["stt_model"] or stt["model"]
        self.deepl = deepl.Translator(cfg["deepl_key"])
        self.speaking = threading.Event()
        self.mute_until = 0.0
        self.phone = None

    def target_lang(self):
        lang = self.cfg["target_lang"]
        if lang == "AUTO":
            return self.shared.player_lang or "EN"
        return lang

    def transcribe(self, wav):
        result = self.stt_client.audio.transcriptions.create(
            model=self.stt_model,
            file=("audio.wav", wav, "audio/wav"),
        )
        return (result.text or "").strip()

    def translate(self, text, target):
        result = self.deepl.translate_text(text, target_lang=deepl_target(target))
        return result.text, (result.detected_source_lang or "?").upper()

    def speak(self, text, lang):
        if sys.platform != "win32":
            return
        local = not self.output_device
        self.speaking.set()
        if local:
            self.shared.local_playback.set()
        wav_file = ""
        try:
            if local:
                run_tts(text, lang, self.cfg["tts_rate"])
            else:
                fd, wav_file = tempfile.mkstemp(suffix=".wav")
                os.close(fd)
                run_tts(text, lang, self.cfg["tts_rate"], wav_file)
                play_wav(wav_file, self.output_device)
        except Exception as e:
            self.log(f"   (Sprachausgabe fehlgeschlagen: {e})")
        finally:
            if wav_file:
                try:
                    os.remove(wav_file)
                except OSError:
                    pass
            # Kurz nachlaufen lassen, damit der Rest der Ansage nicht mit aufgenommen wird.
            self.mute_until = time.monotonic() + 0.4
            self.speaking.clear()
            if local:
                self.shared.local_until = time.monotonic() + 0.4
                self.shared.local_playback.clear()

    def is_muted(self):
        own = self.speaking.is_set() or time.monotonic() < self.mute_until
        return own or self.shared.local_busy()

    def handle(self, segment):
        started = time.monotonic()
        text = self.transcribe(to_wav_bytes(segment, RECORD_RATE))
        if not text or text.lower() in HALLUCINATIONS or len(text) < 2:
            return
        target = self.target_lang()
        target_base = target.split("-")[0]
        translated, source = self.translate(text, target)
        source_base = source.split("-")[0]
        took = time.monotonic() - started
        stamp = datetime.now().strftime("%H:%M:%S")
        same = source_base == target_base

        if self.direction == "out":
            # Eigene Stimme: die Mitspieler hören nur die Ansage, also auch dann
            # sprechen, wenn schon in der Zielsprache geredet wurde.
            self.log(f"[{stamp}] Du ({source}): {text}")
            if not same:
                self.log(f"         -> {target_base}: {translated}   ({took:.1f}s)")
            self.speak(text if same else translated, target_base)
            return

        if same:
            self.log(f"[{stamp}] ({source}) {text}")
            if self.phone:
                self.phone.add(source, text, None, target_base)
            return

        self.shared.player_lang = source_base
        self.log(f"[{stamp}] {source}: {text}")
        self.log(f"         {target_base}: {translated}   ({took:.1f}s)")
        if self.phone:
            self.phone.add(source, text, translated, target_base)
        if self.cfg["speak"]:
            self.speak(translated, target_base)


def explain_error(e):
    name = type(e).__name__
    msg = str(e)
    if name == "AuthenticationError":
        return "Key für die Spracherkennung (Groq/OpenAI) ungültig. Key prüfen."
    if name == "RateLimitError" and "insufficient_quota" in msg:
        return "OpenAI-Guthaben aufgebraucht oder nicht aufgeladen (platform.openai.com -> Billing)."
    if name == "RateLimitError":
        return "Gratis-Limit der Spracherkennung erreicht. Kurz warten, dann geht es weiter."
    if name == "AuthorizationException":
        return "DeepL-Key ungültig. Key prüfen."
    if name == "QuotaExceededException":
        return "DeepL-Monatskontingent aufgebraucht."
    if name in ("APIConnectionError", "ConnectionException"):
        return "Keine Verbindung zum Dienst. Internet prüfen."
    return f"{name}: {msg}"


def com_init():
    """soundcard braucht unter Windows COM in jedem Thread, der Audiogeräte öffnet."""
    if sys.platform == "win32":
        import ctypes
        # Rückgabewert egal: "schon initialisiert" ist auch in Ordnung.
        ctypes.windll.ole32.CoInitializeEx(None, 0)


class Engine:
    """Aufnahme + Übersetzung in Hintergrund-Threads; von Konsole und Fenster genutzt."""

    def __init__(self, cfg, log=print, on_level=None, shared=None):
        self.cfg = cfg
        self.shared = shared
        self.log = log
        self.on_level = on_level
        self.stop_event = threading.Event()
        self.segmenter = SpeechSegmenter(cfg["threshold"], cfg["silence"],
                                         cfg["min_speech"], cfg["max_speech"])
        self.pipeline = None
        self.phone_url = None
        self.thread = None
        self.jobs = queue.Queue(maxsize=4)

    def missing_keys(self):
        stt = STT_PROVIDERS[self.cfg["stt_provider"]]
        return [name for key, name in ((stt["key"], stt["name"] + "-Key"), ("deepl_key", "DeepL-Key"))
                if not self.cfg[key]]

    def set_threshold(self, value):
        self.cfg["threshold"] = value
        self.segmenter.threshold = value

    def start(self):
        self.pipeline = Pipeline(self.cfg, log=self.log, shared=self.shared)
        if self.cfg["phone_view"]:
            self.pipeline.phone = PhoneView(self.cfg["phone_port"])
            try:
                self.phone_url = self.pipeline.phone.start()
                self.log(f"Handy-Anzeige: {self.phone_url}  (Handy muss im selben WLAN sein)")
            except OSError as e:
                self.pipeline.phone = None
                self.log(f"Handy-Anzeige konnte nicht starten ({e}). Anderen PHONE_PORT wählen.")
        threading.Thread(target=self._work, daemon=True).start()
        self.thread = threading.Thread(target=self._record, daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=2)
        if self.pipeline and self.pipeline.phone:
            self.pipeline.phone.stop()

    def running(self):
        return bool(self.thread and self.thread.is_alive())

    def _work(self):
        com_init()  # Ausgabe auf VB-Cable öffnet Audiogeräte in diesem Thread
        while not self.stop_event.is_set():
            try:
                segment = self.jobs.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                self.pipeline.handle(segment)
            except Exception as e:
                self.log(f"   FEHLER: {explain_error(e)}")

    def _record(self):
        try:
            com_init()
            mic = find_input(self.cfg["source"], self.cfg["device"], self.log)
            if self.cfg.get("direction") == "out":
                target = self.cfg["target_lang"]
                target = "Sprache der Mitspieler (automatisch)" if target == "AUTO" else target
                self.log(f"Deine Stimme: {mic.name} -> {target} -> {self.cfg['output_device']}")
            else:
                self.log(f"Mitspieler: {mic.name} -> {self.cfg['target_lang']}")
            frames = int(RECORD_RATE * BLOCK_SECONDS)
            with mic.recorder(samplerate=RECORD_RATE) as rec:
                while not self.stop_event.is_set():
                    block = to_mono(rec.record(numframes=frames))
                    if self.on_level:
                        self.on_level(rms(block))
                    if self.pipeline.is_muted():
                        self.segmenter.reset()
                        continue
                    segment = self.segmenter.feed(block)
                    if segment is None:
                        continue
                    if self.jobs.full():
                        self.jobs.get_nowait()  # zu viel Rückstau: ältestes Stück verwerfen
                        self.log("   (Übersetzung hinkt hinterher, ein Stück übersprungen)")
                    self.jobs.put(segment)
        except Exception as e:
            self.log(f"FEHLER bei der Tonaufnahme: {e}")
        finally:
            self.stop_event.set()


# ---------------------------------------------------------------- Konsole

def show_level(cfg):
    mic = find_input(cfg["source"], cfg["device"])
    print(f"Pegelanzeige für: {mic.name}  (Strg+C beendet)")
    print(f"Aktuelle Schwelle VOLUME_THRESHOLD = {cfg['threshold']}\n")
    frames = int(RECORD_RATE * BLOCK_SECONDS)
    with mic.recorder(samplerate=RECORD_RATE) as rec:
        while True:
            level = rms(to_mono(rec.record(numframes=frames)))
            bar = "#" * min(60, int(level * 600))
            mark = "  <- Sprache" if level >= cfg["threshold"] else ""
            print(f"{level:0.4f} {bar}{mark}")


def create_engines(cfg, log=print, on_level=None):
    """Eine Engine pro eingeschalteter Richtung; beide teilen sich den Zustand."""
    shared = SharedState()
    engines = {}
    for direction, key in (("in", "in_enabled"), ("out", "out_enabled")):
        if cfg[key]:
            level = (lambda v, d=direction: on_level(d, v)) if on_level else None
            engines[direction] = Engine(direction_config(cfg, direction), log=log,
                                        on_level=level, shared=shared)
    return engines


def run(cfg):
    engines = create_engines(cfg)
    if not engines:
        print("Beide Richtungen sind aus (IN_ENABLED / OUT_ENABLED in .env).")
        return 1
    missing = next(iter(engines.values())).missing_keys()
    if missing:
        print("Es fehlen API-Keys in der Datei .env: " + ", ".join(missing))
        print("Siehe README.md, Schritt 3.")
        return 1
    for engine in engines.values():
        engine.start()
    print(f"Sprachausgabe: {'an' if cfg['speak'] else 'aus'}. Strg+C beendet.\n")
    try:
        while all(e.running() for e in engines.values()):
            time.sleep(0.2)
    finally:
        for engine in engines.values():
            engine.stop()
    return 1


def main():
    warnings.filterwarnings("ignore", message=".*discontinuity.*")
    try:
        import soundcard  # noqa: F401
        import deepl  # noqa: F401
        import openai  # noqa: F401
    except ImportError as e:
        print(f"Fehlendes Paket ({e.name}). Bitte zuerst install.bat ausführen.")
        return 1

    cfg = load_config()
    args = sys.argv[1:]
    try:
        if "--geraete" in args:
            list_devices()
            return 0
        if "--pegel" in args:
            show_level(cfg)
            return 0
        return run(cfg)
    except KeyboardInterrupt:
        print("\nBeendet.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
