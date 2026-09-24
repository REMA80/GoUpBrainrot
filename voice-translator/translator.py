"""
Voice-Chat-Übersetzer (Prototyp, Windows)

Ablauf:
  Ton aufnehmen (Lautsprecher-Loopback oder Mikrofon)
  -> bei Sprechpause ein Stück abschneiden
  -> OpenAI Speech-to-Text (Sprache wird automatisch erkannt)
  -> DeepL übersetzt in die Zielsprache
  -> Text im Fenster + Windows-Sprachausgabe

Start:  python translator.py
Hilfen: python translator.py --geraete   (Audiogeräte auflisten)
        python translator.py --pegel     (Lautstärke live anzeigen, zum Einstellen)
"""

import io
import os
import queue
import subprocess
import sys
import threading
import time
import warnings
import wave
from collections import deque
from datetime import datetime

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


def load_config():
    try:
        from dotenv import load_dotenv
        load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))
    except ImportError:
        pass

    def num(name, default):
        try:
            return float(os.getenv(name, default))
        except ValueError:
            print(f"Warnung: {name} in .env ist keine Zahl, nehme {default}.")
            return float(default)

    return {
        "openai_key": os.getenv("OPENAI_API_KEY", "").strip(),
        "deepl_key": os.getenv("DEEPL_API_KEY", "").strip(),
        "target_lang": os.getenv("TARGET_LANG", "DE").strip().upper(),
        "source": os.getenv("AUDIO_SOURCE", "loopback").strip().lower(),
        "device": os.getenv("AUDIO_DEVICE", "").strip(),
        "speak": os.getenv("SPEAK", "1").strip() not in ("0", "nein", "no", "false"),
        "threshold": num("VOLUME_THRESHOLD", "0.01"),
        "silence": num("SILENCE_SECONDS", "0.8"),
        "min_speech": num("MIN_SPEECH_SECONDS", "0.5"),
        "max_speech": num("MAX_SPEECH_SECONDS", "15"),
        "stt_model": os.getenv("STT_MODEL", "whisper-1").strip(),
        "tts_rate": int(num("TTS_RATE", "1")),
    }


# ---------------------------------------------------------------- Audio

def find_input(source, device_filter):
    """Liefert das soundcard-Aufnahmegerät für Loopback oder Mikrofon."""
    import soundcard as sc

    wanted = device_filter.lower()
    if source == "mic":
        mics = sc.all_microphones()
        if wanted:
            for m in mics:
                if wanted in m.name.lower():
                    return m
            print(f"Kein Mikrofon mit '{device_filter}' im Namen gefunden, nehme Standard.")
        return sc.default_microphone()

    speaker = sc.default_speaker()
    if wanted:
        for s in sc.all_speakers():
            if wanted in s.name.lower():
                speaker = s
                break
        else:
            print(f"Kein Ausgabegerät mit '{device_filter}' im Namen gefunden, nehme Standard.")
    return sc.get_microphone(id=str(speaker.name), include_loopback=True)


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


# ---------------------------------------------------------------- Dienste

def deepl_target(lang):
    # DeepL verlangt bei Englisch/Portugiesisch als Ziel eine Variante.
    return {"EN": "EN-US", "PT": "PT-PT"}.get(lang, lang)


class Pipeline:
    def __init__(self, cfg):
        import deepl
        from openai import OpenAI

        self.cfg = cfg
        self.openai = OpenAI(api_key=cfg["openai_key"])
        self.deepl = deepl.Translator(cfg["deepl_key"])
        self.target = deepl_target(cfg["target_lang"])
        self.target_base = cfg["target_lang"].split("-")[0]
        self.speaking = threading.Event()
        self.mute_until = 0.0

    def transcribe(self, wav):
        result = self.openai.audio.transcriptions.create(
            model=self.cfg["stt_model"],
            file=("audio.wav", wav, "audio/wav"),
        )
        return (result.text or "").strip()

    def translate(self, text):
        result = self.deepl.translate_text(text, target_lang=self.target)
        return result.text, (result.detected_source_lang or "?").upper()

    def speak(self, text):
        if sys.platform != "win32":
            return
        script = (
            "Add-Type -AssemblyName System.Speech; "
            "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
            "$v = $s.GetInstalledVoices() | Where-Object "
            "{ $_.VoiceInfo.Culture.TwoLetterISOLanguageName -eq $env:VT_LANG } | Select-Object -First 1; "
            "if ($v) { $s.SelectVoice($v.VoiceInfo.Name) }; "
            "$s.Rate = [int]$env:VT_RATE; "
            "$s.Speak($env:VT_TEXT)"
        )
        # Text über Umgebungsvariable statt Kommandozeile: keine Probleme mit
        # Anführungszeichen oder Sonderzeichen im übersetzten Satz.
        env = dict(os.environ, VT_TEXT=text, VT_RATE=str(self.cfg["tts_rate"]),
                   VT_LANG=self.target_base.lower())
        self.speaking.set()
        try:
            subprocess.run(
                ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
                env=env, timeout=60, creationflags=subprocess.CREATE_NO_WINDOW,
            )
        except Exception as e:
            print(f"   (Sprachausgabe fehlgeschlagen: {e})")
        finally:
            # Kurz nachlaufen lassen, damit der Rest der Ansage nicht mit aufgenommen wird.
            self.mute_until = time.monotonic() + 0.4
            self.speaking.clear()

    def is_muted(self):
        return self.speaking.is_set() or time.monotonic() < self.mute_until

    def handle(self, segment):
        started = time.monotonic()
        text = self.transcribe(to_wav_bytes(segment, RECORD_RATE))
        if not text or text.lower() in HALLUCINATIONS or len(text) < 2:
            return
        translated, source = self.translate(text)
        took = time.monotonic() - started
        stamp = datetime.now().strftime("%H:%M:%S")

        if source.split("-")[0] == self.target_base:
            print(f"[{stamp}] ({source}) {text}")
            return

        print(f"[{stamp}] {source}: {text}")
        print(f"         {self.target_base}: {translated}   ({took:.1f}s)")
        if self.cfg["speak"]:
            self.speak(translated)


def explain_error(e):
    name = type(e).__name__
    msg = str(e)
    if name == "AuthenticationError":
        return "OpenAI-Key ungültig. OPENAI_API_KEY in .env prüfen."
    if name == "RateLimitError" and "quota" in msg.lower():
        return "OpenAI-Guthaben aufgebraucht oder nicht aufgeladen (platform.openai.com -> Billing)."
    if name == "AuthorizationException":
        return "DeepL-Key ungültig. DEEPL_API_KEY in .env prüfen."
    if name == "QuotaExceededException":
        return "DeepL-Monatskontingent aufgebraucht."
    if name in ("APIConnectionError", "ConnectionException"):
        return "Keine Verbindung zum Dienst. Internet prüfen."
    return f"{name}: {msg}"


def worker(pipeline, jobs):
    while True:
        segment = jobs.get()
        try:
            pipeline.handle(segment)
        except Exception as e:
            print(f"   FEHLER: {explain_error(e)}")


# ---------------------------------------------------------------- Modi

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


def run(cfg):
    missing = [k for k, v in (("OPENAI_API_KEY", cfg["openai_key"]),
                              ("DEEPL_API_KEY", cfg["deepl_key"])) if not v]
    if missing:
        print("Es fehlen API-Keys in der Datei .env: " + ", ".join(missing))
        print("Siehe README.md, Schritt 3.")
        return 1

    pipeline = Pipeline(cfg)
    jobs = queue.Queue(maxsize=4)
    threading.Thread(target=worker, args=(pipeline, jobs), daemon=True).start()

    segmenter = SpeechSegmenter(cfg["threshold"], cfg["silence"],
                                cfg["min_speech"], cfg["max_speech"])
    mic = find_input(cfg["source"], cfg["device"])
    frames = int(RECORD_RATE * BLOCK_SECONDS)

    print(f"Höre auf: {mic.name}")
    print(f"Übersetze automatisch erkannte Sprache -> {cfg['target_lang']}. "
          f"Sprachausgabe: {'an' if cfg['speak'] else 'aus'}. Strg+C beendet.\n")

    # Aufnahme bleibt im Hauptthread: soundcard braucht unter Windows die
    # COM-Initialisierung des Threads, in dem das Gerät geöffnet wurde.
    with mic.recorder(samplerate=RECORD_RATE) as rec:
        while True:
            block = to_mono(rec.record(numframes=frames))
            if pipeline.is_muted():
                segmenter.reset()
                continue
            segment = segmenter.feed(block)
            if segment is None:
                continue
            if jobs.full():
                jobs.get_nowait()  # zu viel Rückstau: ältestes Stück verwerfen
                print("   (Übersetzung hinkt hinterher, ein Stück übersprungen)")
            jobs.put(segment)


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
