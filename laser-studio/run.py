"""Startet Goose Village Laser Studio lokal und öffnet den Browser.

Aufruf:  python run.py            (Standard: Port 8765, Browser öffnet sich)
         python run.py --port 9000 --no-browser
"""

from __future__ import annotations

import argparse
import logging
import sys
import webbrowser
from logging.handlers import RotatingFileHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

if sys.version_info < (3, 10):
    sys.exit("Fehler: Python 3.10 oder neuer wird benötigt (gefunden: %s)." % sys.version.split()[0])

from goose_laser import __version__  # noqa: E402
from goose_laser.server.app import make_server  # noqa: E402


def setup_logging() -> Path:
    log_dir = ROOT / "logs"
    log_dir.mkdir(exist_ok=True)
    log_file = log_dir / "app.log"
    handler = RotatingFileHandler(log_file, maxBytes=1_000_000, backupCount=3, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    console = logging.StreamHandler()
    console.setLevel(logging.WARNING)
    logging.basicConfig(level=logging.INFO, handlers=[handler, console])
    return log_file


def main() -> int:
    parser = argparse.ArgumentParser(description="Goose Village Laser Studio")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-browser", action="store_true", help="Browser nicht automatisch öffnen")
    args = parser.parse_args()

    log_file = setup_logging()
    server = None
    for port in range(args.port, args.port + 10):
        try:
            server = make_server(port)
            break
        except OSError:
            continue
    if server is None:
        print(f"Fehler: Kein freier Port zwischen {args.port} und {args.port + 9} gefunden.")
        return 1

    url = f"http://127.0.0.1:{server.server_port}/"
    logging.getLogger("goose_laser").info("Start Version %s auf %s", __version__, url)
    print(f"Goose Village Laser Studio {__version__}")
    print(f"Oberfläche: {url}")
    print(f"Protokoll:  {log_file}")
    print("Beenden mit Strg+C oder durch Schließen dieses Fensters.")
    if not args.no_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nBeendet.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
