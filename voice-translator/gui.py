"""
Fenster-Version des Voice-Chat-Übersetzers.

Start:  python gui.py   (bzw. VoiceTranslator.exe)
"""

import queue
import sys
import tkinter as tk
import warnings
from tkinter import messagebox, scrolledtext, ttk

import translator as core

DEFAULT_DEVICE = "(Windows-Standard)"
PROVIDER_LABELS = {"groq": "Groq (Gratis-Kontingent)", "openai": "OpenAI (kostenpflichtig)"}
SOURCES = {"loopback": "Lautsprecher / Kopfhörer", "mic": "Mikrofon"}
# Zielsprachen, die DeepL unterstützt (Auswahl); eigene Codes können eingetippt werden.
LANGUAGES = ["DE", "EN", "FR", "ES", "IT", "NL", "PL", "PT", "TR", "RU", "UK",
             "CS", "SV", "DA", "FI", "EL", "HU", "RO", "JA", "KO", "ZH"]
AUTO_LABEL = "AUTO"
# Schieberegler 1..100 entspricht Schwelle 0.001..0.100
SLIDER_SCALE = 1000


class LevelControls:
    """Regler "Mindest-Lautstärke" + Pegelanzeige für eine Richtung."""

    def __init__(self, parent, row, value, on_change, pad):
        ttk.Label(parent, text="Mindest-Lautstärke:").grid(row=row, column=0, sticky="w", **pad)
        slider_row = ttk.Frame(parent)
        slider_row.grid(row=row, column=1, columnspan=2, sticky="ew", **pad)
        slider_row.columnconfigure(0, weight=1)
        self.var = tk.DoubleVar(value=value * SLIDER_SCALE)
        ttk.Scale(slider_row, from_=1, to=100, variable=self.var,
                  command=lambda _: on_change(self.value())).grid(row=0, column=0, sticky="ew")
        self.value_label = ttk.Label(slider_row, width=7)
        self.value_label.grid(row=0, column=1, padx=(8, 0))

        ttk.Label(parent, text="Pegel:").grid(row=row + 1, column=0, sticky="w", **pad)
        level_row = ttk.Frame(parent)
        level_row.grid(row=row + 1, column=1, columnspan=2, sticky="ew", **pad)
        level_row.columnconfigure(0, weight=1)
        self.bar = ttk.Progressbar(level_row, maximum=100)
        self.bar.grid(row=0, column=0, sticky="ew")
        self.speech_label = ttk.Label(level_row, width=10)
        self.speech_label.grid(row=0, column=1, padx=(8, 0))
        self.refresh_label()

    def value(self):
        self.refresh_label()
        return round(self.var.get() / SLIDER_SCALE, 4)

    def refresh_label(self):
        self.value_label.config(text=f"{self.var.get() / SLIDER_SCALE:.3f}")

    def show(self, level, active):
        self.bar["value"] = min(100, level * SLIDER_SCALE)
        speech = active and level >= self.var.get() / SLIDER_SCALE
        self.speech_label.config(text="● Sprache" if speech else "")


class App:
    def __init__(self, root):
        self.root = root
        self.cfg = core.load_config()
        self.engines = {}
        self.messages = queue.Queue()
        self.levels = {"in": 0.0, "out": 0.0}

        root.title("Voice-Übersetzer")
        root.geometry("660x860")
        root.minsize(560, 640)
        root.protocol("WM_DELETE_WINDOW", self.on_close)

        self.build()
        self.refresh_devices()
        self.poll()

    # ------------------------------------------------------------ Aufbau

    def build(self):
        pad = {"padx": 8, "pady": 3}
        cfg = self.cfg

        # --- Zugang
        keys = ttk.Frame(self.root, padding=(8, 8, 8, 0))
        keys.pack(fill="x")
        keys.columnconfigure(1, weight=1)

        ttk.Label(keys, text="Spracherkennung:").grid(row=0, column=0, sticky="w", **pad)
        self.provider_var = tk.StringVar(value=PROVIDER_LABELS[cfg["stt_provider"]])
        provider_box = ttk.Combobox(keys, textvariable=self.provider_var, state="readonly",
                                    values=list(PROVIDER_LABELS.values()))
        provider_box.grid(row=0, column=1, sticky="ew", **pad)
        provider_box.bind("<<ComboboxSelected>>", lambda e: self.show_stt_key())

        # Ein Eingabefeld, das je nach Anbieter den Groq- oder den OpenAI-Key zeigt;
        # beide Keys bleiben gespeichert, damit man hin- und herwechseln kann.
        self.stt_key_label = ttk.Label(keys)
        self.stt_key_label.grid(row=1, column=0, sticky="w", **pad)
        self.key_vars = {p: tk.StringVar(value=cfg[core.STT_PROVIDERS[p]["key"]])
                         for p in core.STT_PROVIDERS}
        self.stt_key_entry = ttk.Entry(keys, show="•")
        self.stt_key_entry.grid(row=1, column=1, sticky="ew", **pad)
        self.show_stt_key()

        ttk.Label(keys, text="DeepL-Key:").grid(row=2, column=0, sticky="w", **pad)
        self.deepl_var = tk.StringVar(value=cfg["deepl_key"])
        ttk.Entry(keys, textvariable=self.deepl_var, show="•").grid(
            row=2, column=1, sticky="ew", **pad)

        # --- Richtung 1: Mitspieler -> ich
        incoming = ttk.LabelFrame(self.root, text=" Mitspieler → ich ", padding=4)
        incoming.pack(fill="x", padx=8, pady=(8, 0))
        incoming.columnconfigure(1, weight=1)

        self.in_enabled = tk.BooleanVar(value=cfg["in_enabled"])
        ttk.Checkbutton(incoming, text="aktiv", variable=self.in_enabled).grid(
            row=0, column=0, sticky="w", **pad)

        ttk.Label(incoming, text="Zuhören bei:").grid(row=1, column=0, sticky="w", **pad)
        self.source_var = tk.StringVar(value=SOURCES.get(cfg["source"], SOURCES["loopback"]))
        source_box = ttk.Combobox(incoming, textvariable=self.source_var, state="readonly",
                                  values=list(SOURCES.values()))
        source_box.grid(row=1, column=1, columnspan=2, sticky="ew", **pad)
        source_box.bind("<<ComboboxSelected>>", lambda e: self.refresh_devices())

        ttk.Label(incoming, text="Gerät:").grid(row=2, column=0, sticky="w", **pad)
        self.device_var = tk.StringVar(value=cfg["device"] or DEFAULT_DEVICE)
        self.device_box = ttk.Combobox(incoming, textvariable=self.device_var, state="readonly")
        self.device_box.grid(row=2, column=1, sticky="ew", **pad)
        ttk.Button(incoming, text="Neu laden", command=self.refresh_devices).grid(
            row=2, column=2, **pad)

        ttk.Label(incoming, text="Übersetzen nach:").grid(row=3, column=0, sticky="w", **pad)
        lang_row = ttk.Frame(incoming)
        lang_row.grid(row=3, column=1, columnspan=2, sticky="w", **pad)
        self.lang_var = tk.StringVar(value=cfg["target_lang"])
        ttk.Combobox(lang_row, textvariable=self.lang_var, values=LANGUAGES, width=8).pack(
            side="left")
        self.speak_var = tk.BooleanVar(value=cfg["speak"])
        ttk.Checkbutton(lang_row, text="am PC vorlesen", variable=self.speak_var).pack(
            side="left", padx=16)

        self.in_level = LevelControls(incoming, 4, cfg["threshold"],
                                      lambda v: self.on_threshold("in", v), pad)

        # --- Richtung 2: ich -> Mitspieler
        outgoing = ttk.LabelFrame(self.root, text=" Ich → Mitspieler (über VB-Cable) ",
                                  padding=4)
        outgoing.pack(fill="x", padx=8, pady=(8, 0))
        outgoing.columnconfigure(1, weight=1)

        self.out_enabled = tk.BooleanVar(value=cfg["out_enabled"])
        ttk.Checkbutton(outgoing, text="aktiv", variable=self.out_enabled).grid(
            row=0, column=0, sticky="w", **pad)

        ttk.Label(outgoing, text="Mein Mikrofon:").grid(row=1, column=0, sticky="w", **pad)
        self.out_device_var = tk.StringVar(value=cfg["out_device"] or DEFAULT_DEVICE)
        self.out_device_box = ttk.Combobox(outgoing, textvariable=self.out_device_var,
                                           state="readonly")
        self.out_device_box.grid(row=1, column=1, columnspan=2, sticky="ew", **pad)

        ttk.Label(outgoing, text="Übersetzen nach:").grid(row=2, column=0, sticky="w", **pad)
        out_lang_row = ttk.Frame(outgoing)
        out_lang_row.grid(row=2, column=1, columnspan=2, sticky="w", **pad)
        self.out_lang_var = tk.StringVar(value=cfg["out_target"])
        ttk.Combobox(out_lang_row, textvariable=self.out_lang_var,
                     values=[AUTO_LABEL] + LANGUAGES, width=8).pack(side="left")
        ttk.Label(out_lang_row, text="AUTO = Sprache der Mitspieler",
                  foreground="gray").pack(side="left", padx=12)

        ttk.Label(outgoing, text="Ausgabe an:").grid(row=3, column=0, sticky="w", **pad)
        self.out_output_var = tk.StringVar(value=cfg["out_output"])
        self.out_output_box = ttk.Combobox(outgoing, textvariable=self.out_output_var,
                                           state="readonly")
        self.out_output_box.grid(row=3, column=1, columnspan=2, sticky="ew", **pad)

        self.out_level = LevelControls(outgoing, 4, cfg["out_threshold"],
                                       lambda v: self.on_threshold("out", v), pad)

        # --- Allgemein + Start
        bottom = ttk.Frame(self.root, padding=(8, 6, 8, 4))
        bottom.pack(fill="x")
        self.phone_var = tk.BooleanVar(value=cfg["phone_view"])
        ttk.Checkbutton(bottom, text="Handy-Anzeige", variable=self.phone_var).pack(side="left")
        self.topmost_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(bottom, text="Immer im Vordergrund", variable=self.topmost_var,
                        command=self.on_topmost).pack(side="left", padx=12)

        actions = ttk.Frame(self.root, padding=(8, 0, 8, 6))
        actions.pack(fill="x")
        self.start_button = ttk.Button(actions, text="▶ Start", command=self.toggle)
        self.start_button.pack(side="left")
        self.status = ttk.Label(actions, text="Gestoppt")
        self.status.pack(side="left", padx=12)

        self.output = scrolledtext.ScrolledText(self.root, wrap="word", height=8,
                                                font=("Segoe UI", 12), state="disabled")
        self.output.pack(fill="both", expand=True, padx=8, pady=(0, 8))

        if not (self.key_vars[cfg["stt_provider"]].get() and cfg["deepl_key"]):
            self.write("Willkommen! Trage oben deine API-Keys ein und drücke Start.\n"
                       "Wie du die Keys bekommst, steht in der README (Schritt 1).\n")

    # ------------------------------------------------------------ Aktionen

    def provider_key(self):
        for key, label in PROVIDER_LABELS.items():
            if label == self.provider_var.get():
                return key
        return "groq"

    def show_stt_key(self):
        provider = self.provider_key()
        self.stt_key_label.config(text=core.STT_PROVIDERS[provider]["name"] + "-Key:")
        self.stt_key_entry.config(textvariable=self.key_vars[provider])

    def source_key(self):
        for key, label in SOURCES.items():
            if label == self.source_var.get():
                return key
        return "loopback"

    def refresh_devices(self):
        try:
            incoming = core.device_names(self.source_key())
            mics = core.device_names("mic")
            speakers = core.device_names("loopback")
        except Exception as e:
            incoming = mics = speakers = []
            self.write(f"Audiogeräte konnten nicht gelesen werden: {e}\n")

        for box, var, names in ((self.device_box, self.device_var, incoming),
                                (self.out_device_box, self.out_device_var, mics)):
            box["values"] = [DEFAULT_DEVICE] + names
            if var.get() not in box["values"]:
                var.set(DEFAULT_DEVICE)

        # Ausgabegerät: gespeichert ist evtl. nur ein Namensteil wie "CABLE Input".
        self.out_output_box["values"] = speakers
        wanted = self.out_output_var.get().lower()
        if self.out_output_var.get() not in speakers:
            match = next((n for n in speakers if wanted and wanted in n.lower()), None)
            if match:
                self.out_output_var.set(match)

    def on_threshold(self, direction, value):
        if direction in self.engines:
            self.engines[direction].set_threshold(value)

    def on_topmost(self):
        self.root.attributes("-topmost", self.topmost_var.get())

    def collect(self):
        device = self.device_var.get()
        out_device = self.out_device_var.get()
        self.cfg.update(
            stt_provider=self.provider_key(),
            groq_key=self.key_vars["groq"].get().strip(),
            openai_key=self.key_vars["openai"].get().strip(),
            deepl_key=self.deepl_var.get().strip(),
            in_enabled=self.in_enabled.get(),
            target_lang=(self.lang_var.get().strip().upper() or "DE"),
            source=self.source_key(),
            device="" if device == DEFAULT_DEVICE else device,
            speak=self.speak_var.get(),
            threshold=self.in_level.value(),
            out_enabled=self.out_enabled.get(),
            out_device="" if out_device == DEFAULT_DEVICE else out_device,
            out_target=(self.out_lang_var.get().strip().upper() or AUTO_LABEL),
            out_output=self.out_output_var.get().strip(),
            out_threshold=self.out_level.value(),
            phone_view=self.phone_var.get(),
        )

    def save(self):
        try:
            core.save_config(self.cfg)
        except OSError as e:
            self.write(f"Einstellungen konnten nicht gespeichert werden: {e}\n")

    def check_start(self):
        """Gibt eine Fehlermeldung zurück, wenn nicht gestartet werden kann."""
        if not (self.cfg["in_enabled"] or self.cfg["out_enabled"]):
            return "Bitte mindestens eine Richtung auf „aktiv“ setzen."
        if self.cfg["out_enabled"]:
            if not self.cfg["out_output"]:
                return "Bei „Ich → Mitspieler“ ein Ausgabegerät wählen (CABLE Input)."
            try:
                core.find_output(self.cfg["out_output"])
            except Exception:
                return ("Das Ausgabegerät „" + self.cfg["out_output"] + "“ gibt es nicht.\n\n"
                        "Ist VB-Cable installiert? Danach „Neu laden“ drücken und bei "
                        "„Ausgabe an“ CABLE Input wählen.")
        return None

    def toggle(self):
        if self.engines:
            self.stop()
            return
        self.collect()
        self.save()
        problem = self.check_start()
        if problem:
            messagebox.showwarning("Start nicht möglich", problem)
            return
        engines = core.create_engines(self.cfg, log=self.messages.put, on_level=self.set_level)
        missing = next(iter(engines.values())).missing_keys()
        if missing:
            messagebox.showwarning("Keys fehlen", "Bitte eintragen: " + ", ".join(missing))
            return
        try:
            for engine in engines.values():
                engine.start()
        except Exception as e:
            for engine in engines.values():
                engine.stop()
            messagebox.showerror("Start fehlgeschlagen", core.explain_error(e))
            return
        self.engines = engines
        self.start_button.config(text="■ Stopp")
        self.status.config(text="Läuft")

    def stop(self):
        for engine in self.engines.values():
            engine.stop()
        self.engines = {}
        self.start_button.config(text="▶ Start")
        self.status.config(text="Gestoppt")
        self.levels = {"in": 0.0, "out": 0.0}

    def set_level(self, direction, value):
        # Wird aus den Aufnahme-Threads aufgerufen; das Fenster liest die Werte in poll().
        self.levels[direction] = value

    def write(self, text):
        self.output.config(state="normal")
        self.output.insert("end", text)
        self.output.see("end")
        self.output.config(state="disabled")

    def poll(self):
        while True:
            try:
                self.write(self.messages.get_nowait() + "\n")
            except queue.Empty:
                break
        self.in_level.show(self.levels["in"], "in" in self.engines)
        self.out_level.show(self.levels["out"], "out" in self.engines)
        if self.engines and not all(e.running() for e in self.engines.values()):
            self.stop()  # eine Aufnahme ist mit Fehler beendet worden (steht im Textfeld)
        self.root.after(100, self.poll)

    def on_close(self):
        self.stop()
        self.collect()
        self.save()
        self.root.destroy()


def main():
    warnings.filterwarnings("ignore", message=".*discontinuity.*")
    root = tk.Tk()
    try:
        ttk.Style(root).theme_use("vista" if sys.platform == "win32" else "clam")
    except tk.TclError:
        pass
    try:
        import soundcard  # noqa: F401
        import deepl  # noqa: F401
        import openai  # noqa: F401
    except ImportError as e:
        messagebox.showerror("Fehlendes Paket", f"{e.name} fehlt. Bitte install.bat ausführen.")
        return
    core.com_init()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
