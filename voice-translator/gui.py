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
SOURCES = {"loopback": "Lautsprecher / Kopfhörer (Mitspieler)", "mic": "Mikrofon"}
# Zielsprachen, die DeepL unterstützt (Auswahl); eigene Codes können eingetippt werden.
LANGUAGES = ["DE", "EN", "FR", "ES", "IT", "NL", "PL", "PT", "TR", "RU", "UK",
             "CS", "SV", "DA", "FI", "EL", "HU", "RO", "JA", "KO", "ZH"]
# Schieberegler 1..100 entspricht Schwelle 0.001..0.100
SLIDER_SCALE = 1000


class App:
    def __init__(self, root):
        self.root = root
        self.cfg = core.load_config()
        self.engine = None
        self.messages = queue.Queue()
        self.level = 0.0

        root.title("Voice-Übersetzer")
        root.geometry("640x620")
        root.minsize(520, 480)
        root.protocol("WM_DELETE_WINDOW", self.on_close)

        self.build()
        self.refresh_devices()
        self.poll()

    # ------------------------------------------------------------ Aufbau

    def build(self):
        pad = {"padx": 8, "pady": 4}
        top = ttk.Frame(self.root, padding=8)
        top.pack(fill="x")
        top.columnconfigure(1, weight=1)

        ttk.Label(top, text="Spracherkennung:").grid(row=0, column=0, sticky="w", **pad)
        self.provider_var = tk.StringVar(value=PROVIDER_LABELS[self.cfg["stt_provider"]])
        provider_box = ttk.Combobox(top, textvariable=self.provider_var, state="readonly",
                                    values=list(PROVIDER_LABELS.values()))
        provider_box.grid(row=0, column=1, columnspan=2, sticky="ew", **pad)
        provider_box.bind("<<ComboboxSelected>>", lambda e: self.show_stt_key())

        # Ein Eingabefeld, das je nach Anbieter den Groq- oder den OpenAI-Key zeigt;
        # beide Keys bleiben gespeichert, damit man hin- und herwechseln kann.
        self.stt_key_label = ttk.Label(top)
        self.stt_key_label.grid(row=1, column=0, sticky="w", **pad)
        self.key_vars = {p: tk.StringVar(value=self.cfg[core.STT_PROVIDERS[p]["key"]])
                         for p in core.STT_PROVIDERS}
        self.stt_key_entry = ttk.Entry(top, show="•")
        self.stt_key_entry.grid(row=1, column=1, columnspan=2, sticky="ew", **pad)
        self.show_stt_key()

        ttk.Label(top, text="DeepL-Key:").grid(row=2, column=0, sticky="w", **pad)
        self.deepl_var = tk.StringVar(value=self.cfg["deepl_key"])
        ttk.Entry(top, textvariable=self.deepl_var, show="•").grid(
            row=2, column=1, columnspan=2, sticky="ew", **pad)

        ttk.Label(top, text="Übersetzen nach:").grid(row=3, column=0, sticky="w", **pad)
        self.lang_var = tk.StringVar(value=self.cfg["target_lang"])
        ttk.Combobox(top, textvariable=self.lang_var, values=LANGUAGES, width=8).grid(
            row=3, column=1, sticky="w", **pad)

        ttk.Label(top, text="Zuhören bei:").grid(row=4, column=0, sticky="w", **pad)
        self.source_var = tk.StringVar(value=SOURCES.get(self.cfg["source"], SOURCES["loopback"]))
        source_box = ttk.Combobox(top, textvariable=self.source_var, state="readonly",
                                  values=list(SOURCES.values()))
        source_box.grid(row=4, column=1, columnspan=2, sticky="ew", **pad)
        source_box.bind("<<ComboboxSelected>>", lambda e: self.refresh_devices())

        ttk.Label(top, text="Gerät:").grid(row=5, column=0, sticky="w", **pad)
        self.device_var = tk.StringVar(value=self.cfg["device"] or DEFAULT_DEVICE)
        self.device_box = ttk.Combobox(top, textvariable=self.device_var, state="readonly")
        self.device_box.grid(row=5, column=1, sticky="ew", **pad)
        ttk.Button(top, text="Neu laden", command=self.refresh_devices).grid(row=5, column=2, **pad)

        ttk.Label(top, text="Mindest-Lautstärke:").grid(row=6, column=0, sticky="w", **pad)
        slider_row = ttk.Frame(top)
        slider_row.grid(row=6, column=1, columnspan=2, sticky="ew", **pad)
        slider_row.columnconfigure(0, weight=1)
        self.threshold_var = tk.DoubleVar(value=self.cfg["threshold"] * SLIDER_SCALE)
        ttk.Scale(slider_row, from_=1, to=100, variable=self.threshold_var,
                  command=self.on_threshold).grid(row=0, column=0, sticky="ew")
        self.threshold_label = ttk.Label(slider_row, width=7)
        self.threshold_label.grid(row=0, column=1, padx=(8, 0))

        ttk.Label(top, text="Pegel:").grid(row=7, column=0, sticky="w", **pad)
        level_row = ttk.Frame(top)
        level_row.grid(row=7, column=1, columnspan=2, sticky="ew", **pad)
        level_row.columnconfigure(0, weight=1)
        self.level_bar = ttk.Progressbar(level_row, maximum=100)
        self.level_bar.grid(row=0, column=0, sticky="ew")
        self.level_label = ttk.Label(level_row, width=10)
        self.level_label.grid(row=0, column=1, padx=(8, 0))

        options = ttk.Frame(top)
        options.grid(row=8, column=0, columnspan=3, sticky="w", **pad)
        self.speak_var = tk.BooleanVar(value=self.cfg["speak"])
        ttk.Checkbutton(options, text="Am PC vorlesen", variable=self.speak_var).pack(side="left")
        self.phone_var = tk.BooleanVar(value=self.cfg["phone_view"])
        ttk.Checkbutton(options, text="Handy-Anzeige", variable=self.phone_var).pack(
            side="left", padx=12)
        self.topmost_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(options, text="Immer im Vordergrund", variable=self.topmost_var,
                        command=self.on_topmost).pack(side="left")

        actions = ttk.Frame(top)
        actions.grid(row=9, column=0, columnspan=3, sticky="ew", **pad)
        self.start_button = ttk.Button(actions, text="▶ Start", command=self.toggle)
        self.start_button.pack(side="left")
        self.status = ttk.Label(actions, text="Gestoppt")
        self.status.pack(side="left", padx=12)

        self.output = scrolledtext.ScrolledText(self.root, wrap="word", height=12,
                                                font=("Segoe UI", 12), state="disabled")
        self.output.pack(fill="both", expand=True, padx=8, pady=(0, 8))

        self.on_threshold()
        if not (self.key_vars[self.cfg["stt_provider"]].get() and self.cfg["deepl_key"]):
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
            names = core.device_names(self.source_key())
        except Exception as e:
            names = []
            self.write(f"Audiogeräte konnten nicht gelesen werden: {e}\n")
        self.device_box["values"] = [DEFAULT_DEVICE] + names
        if self.device_var.get() not in self.device_box["values"]:
            self.device_var.set(DEFAULT_DEVICE)

    def on_threshold(self, _=None):
        value = self.threshold_var.get() / SLIDER_SCALE
        self.threshold_label.config(text=f"{value:.3f}")
        if self.engine:
            self.engine.set_threshold(value)

    def on_topmost(self):
        self.root.attributes("-topmost", self.topmost_var.get())

    def collect(self):
        device = self.device_var.get()
        self.cfg.update(
            stt_provider=self.provider_key(),
            groq_key=self.key_vars["groq"].get().strip(),
            openai_key=self.key_vars["openai"].get().strip(),
            deepl_key=self.deepl_var.get().strip(),
            target_lang=(self.lang_var.get().strip().upper() or "DE"),
            source=self.source_key(),
            device="" if device == DEFAULT_DEVICE else device,
            speak=self.speak_var.get(),
            phone_view=self.phone_var.get(),
            threshold=round(self.threshold_var.get() / SLIDER_SCALE, 4),
        )

    def save(self):
        try:
            core.save_config(self.cfg)
        except OSError as e:
            self.write(f"Einstellungen konnten nicht gespeichert werden: {e}\n")

    def toggle(self):
        if self.engine and self.engine.running():
            self.stop()
            return
        self.collect()
        self.save()
        engine = core.Engine(self.cfg, log=self.messages.put, on_level=self.set_level)
        missing = engine.missing_keys()
        if missing:
            messagebox.showwarning("Keys fehlen", "Bitte eintragen: " + ", ".join(missing))
            return
        try:
            engine.start()
        except Exception as e:
            messagebox.showerror("Start fehlgeschlagen", core.explain_error(e))
            return
        self.engine = engine
        self.start_button.config(text="■ Stopp")
        self.status.config(text="Läuft")

    def stop(self):
        if self.engine:
            self.engine.stop()
            self.engine = None
        self.start_button.config(text="▶ Start")
        self.status.config(text="Gestoppt")
        self.set_level(0.0)

    def set_level(self, value):
        # Wird aus dem Aufnahme-Thread aufgerufen; das Fenster liest den Wert in poll().
        self.level = value

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
        threshold = self.threshold_var.get() / SLIDER_SCALE
        self.level_bar["value"] = min(100, self.level * SLIDER_SCALE)
        speech = self.level >= threshold and self.engine is not None
        self.level_label.config(text="● Sprache" if speech else "")
        if self.engine and not self.engine.running():
            self.stop()  # Aufnahme ist mit Fehler beendet worden (steht im Textfeld)
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
