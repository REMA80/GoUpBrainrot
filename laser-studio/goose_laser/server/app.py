"""Lokaler HTTP-Server (nur Python-Standardbibliothek).

Lauscht ausschließlich auf 127.0.0.1, ist also nur vom eigenen PC aus
erreichbar. Liefert die Oberfläche aus ``web/`` und eine kleine JSON-API.
"""

from __future__ import annotations

import json
import logging
import mimetypes
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, urlparse

from goose_laser import __version__
from goose_laser.geometry.box import JOINT_TYPES, LID_TYPES
from goose_laser.service import InputError, calculate_box, export_box_svg

WEB_DIR = (Path(__file__).resolve().parents[2] / "web").resolve()
MAX_BODY_BYTES = 64 * 1024

log = logging.getLogger("goose_laser.server")


class Handler(BaseHTTPRequestHandler):
    server_version = f"GooseLaserStudio/{__version__}"

    # -- Hilfsfunktionen -------------------------------------------------
    def _send(self, status: int, body: bytes, content_type: str, extra: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._send(status, body, "application/json; charset=utf-8")

    def _read_json(self) -> dict | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY_BYTES:
            self._json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"ok": False, "errors": [
                {"field": None, "message": "Anfrage ist zu groß oder ungültig."}]})
            return None
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8") or "{}")
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._json(HTTPStatus.BAD_REQUEST, {"ok": False, "errors": [
                {"field": None, "message": "Anfrage enthält kein gültiges JSON."}]})
            return None
        if not isinstance(data, dict):
            self._json(HTTPStatus.BAD_REQUEST, {"ok": False, "errors": [
                {"field": None, "message": "Ungültige Eingabedaten."}]})
            return None
        return data

    def log_message(self, fmt: str, *args) -> None:  # leiser als Standard
        log.debug("%s - %s", self.address_string(), fmt % args)

    # -- Routen ----------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/api/info":
            self._json(HTTPStatus.OK, {
                "ok": True,
                "version": __version__,
                "lid_types": LID_TYPES,
                "joint_types": JOINT_TYPES,
            })
            return
        if path in ("/", "/index.html"):
            self._static("index.html")
            return
        if path.startswith("/static/"):
            self._static(path[len("/static/"):])
            return
        self._json(HTTPStatus.NOT_FOUND, {"ok": False, "errors": [
            {"field": None, "message": "Nicht gefunden."}]})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path not in ("/api/box/calculate", "/api/box/export"):
            self._json(HTTPStatus.NOT_FOUND, {"ok": False, "errors": [
                {"field": None, "message": "Nicht gefunden."}]})
            return
        data = self._read_json()
        if data is None:
            return
        try:
            if path == "/api/box/calculate":
                self._json(HTTPStatus.OK, {"ok": True, "result": calculate_box(data)})
            else:
                filename, svg = export_box_svg(data)
                self._send(HTTPStatus.OK, svg.encode("utf-8"), "image/svg+xml; charset=utf-8", {
                    "Content-Disposition": f"attachment; filename*=UTF-8''{quote(filename)}",
                })
                log.info("SVG exportiert: %s", filename)
        except InputError as exc:
            self._json(HTTPStatus.UNPROCESSABLE_ENTITY, {"ok": False, "errors": exc.errors})
        except Exception:  # unerwarteter Programmfehler -> protokollieren
            log.exception("Unerwarteter Fehler bei %s", path)
            self._json(HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "errors": [
                {"field": None, "message": "Interner Fehler – Details stehen in logs/app.log."}]})

    def _static(self, rel: str) -> None:
        target = (WEB_DIR / rel).resolve()
        if not target.is_relative_to(WEB_DIR) or not target.is_file():
            self._json(HTTPStatus.NOT_FOUND, {"ok": False, "errors": [
                {"field": None, "message": "Nicht gefunden."}]})
            return
        ctype = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype in ("application/javascript", "image/svg+xml"):
            ctype += "; charset=utf-8"
        self._send(HTTPStatus.OK, target.read_bytes(), ctype)


def make_server(port: int, host: str = "127.0.0.1") -> ThreadingHTTPServer:
    mimetypes.add_type("text/javascript", ".js")
    mimetypes.add_type("text/css", ".css")
    return ThreadingHTTPServer((host, port), Handler)
