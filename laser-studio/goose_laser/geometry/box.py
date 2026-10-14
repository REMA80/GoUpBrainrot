"""Kistenkonstrukteur – Phase 1: Kiste mit stumpfen Verbindungen.

Konstruktionsregeln (Koordinaten in mm, x = Länge, y = Breite, z = Höhe,
die Kiste belegt den Quader [0, L] x [0, B] x [0, H]):

* Vorder- und Rückwand laufen über die volle Außenlänge L.
* Die Seitenwände sitzen zwischen Vorder- und Rückwand (Länge B - 2t).
* Der Boden ist zwischen allen vier Wänden eingesetzt ((L - 2t) x (B - 2t)).
* Deckelvarianten:
    - "offen":       kein Deckel, Wandhöhe = H
    - "eingesetzt":  Deckel wie der Boden zwischen den Wänden, Wandhöhe = H
    - "aufgelegt":   Deckel L x B liegt auf den Wänden, Wandhöhe = H - t

Stumpfe Verbindungen halten nur mit Leim, Nägeln o. Ä. – das wird dem
Nutzer als Hinweis angezeigt.

Die Funktion ``verify_assembly`` beweist rechnerisch, dass die Bauteile
die Kistenwand exakt ausfüllen: alle Teile liegen in der Außenkontur,
keines ragt in den Innenraum, keine zwei Teile überschneiden sich und die
Summe der Teilvolumina entspricht dem Volumen der Kistenwand.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field, asdict

EPS = 1e-6

LID_TYPES = {
    "offen": "Offen (ohne Deckel)",
    "eingesetzt": "Deckel eingesetzt (wie Boden, verleimt)",
    "aufgelegt": "Deckel aufgelegt (volle Außenmaße)",
}

JOINT_TYPES = {
    "stumpf": "Stumpfe Verbindung (verleimen)",
}

# Plausibilitätsgrenzen – keine Materialwerte, nur Schutz vor Tippfehlern.
MAX_OUTER_MM = 3000.0
MAX_THICKNESS_MM = 50.0
MAX_KERF_MM = 2.0


class ValidationError(Exception):
    """Ungültige oder widersprüchliche Eingaben."""

    def __init__(self, errors: list[dict]):
        super().__init__("; ".join(e["message"] for e in errors))
        self.errors = errors


@dataclass(frozen=True)
class Box3D:
    """Achsparalleler Quader [x0, x1] x [y0, y1] x [z0, z1] in mm."""

    x0: float
    y0: float
    z0: float
    x1: float
    y1: float
    z1: float

    @property
    def size(self) -> tuple[float, float, float]:
        return (self.x1 - self.x0, self.y1 - self.y0, self.z1 - self.z0)

    @property
    def volume(self) -> float:
        sx, sy, sz = self.size
        return sx * sy * sz

    def intersection_volume(self, other: "Box3D") -> float:
        dx = min(self.x1, other.x1) - max(self.x0, other.x0)
        dy = min(self.y1, other.y1) - max(self.y0, other.y0)
        dz = min(self.z1, other.z1) - max(self.z0, other.z0)
        if dx <= EPS or dy <= EPS or dz <= EPS:
            return 0.0
        return dx * dy * dz

    def contains(self, other: "Box3D") -> bool:
        return (
            other.x0 >= self.x0 - EPS
            and other.y0 >= self.y0 - EPS
            and other.z0 >= self.z0 - EPS
            and other.x1 <= self.x1 + EPS
            and other.y1 <= self.y1 + EPS
            and other.z1 <= self.z1 + EPS
        )


@dataclass(frozen=True)
class BoxParams:
    length: float  # Außenlänge L (mm)
    width: float  # Außenbreite B (mm)
    height: float  # Außenhöhe H (mm)
    thickness: float  # Materialstärke t (mm)
    kerf: float = 0.0  # Schnittfugenbreite (mm)
    lid: str = "offen"
    joint: str = "stumpf"


@dataclass
class Panel:
    """Ein Bauteil. ``width``/``height`` sind die Nennmaße (fertiges Teil)."""

    key: str
    name: str
    width: float
    height: float
    placement: Box3D

    def cut_size(self, kerf: float) -> tuple[float, float]:
        """Zuschnittmaß der Schnittlinie: Kontur um kerf/2 nach außen versetzt.

        Der Laser trägt auf jeder Seite der Linie etwa kerf/2 ab. Liegt die
        Linie kerf/2 außerhalb des Nennmaßes, hat das fertige Teil das
        Nennmaß.
        """
        return (self.width + kerf, self.height + kerf)


@dataclass
class BoxDesign:
    params: BoxParams
    panels: list[Panel]
    inner_length: float
    inner_width: float
    inner_height: float
    wall_height: float
    warnings: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        kerf = self.params.kerf
        return {
            "params": asdict(self.params),
            "inner": {
                "length": self.inner_length,
                "width": self.inner_width,
                "height": self.inner_height,
            },
            "wall_height": self.wall_height,
            "panels": [
                {
                    "key": p.key,
                    "name": p.name,
                    "width": p.width,
                    "height": p.height,
                    "cut_width": p.cut_size(kerf)[0],
                    "cut_height": p.cut_size(kerf)[1],
                    "placement": asdict(p.placement),
                }
                for p in self.panels
            ],
            "warnings": list(self.warnings),
        }


def _as_number(raw, field_name: str, label: str, errors: list[dict]) -> float | None:
    if isinstance(raw, bool):
        raw = None
    try:
        value = float(raw)
    except (TypeError, ValueError):
        errors.append({"field": field_name, "message": f"{label}: bitte eine Zahl eingeben."})
        return None
    if not math.isfinite(value):
        errors.append({"field": field_name, "message": f"{label}: ungültiger Zahlenwert."})
        return None
    return value


def parse_params(data: dict) -> BoxParams:
    """Liest und prüft Eingaben (z. B. aus JSON). Wirft ValidationError."""
    errors: list[dict] = []
    if not isinstance(data, dict):
        raise ValidationError([{"field": None, "message": "Ungültige Eingabedaten."}])

    labels = {
        "length": "Außenlänge",
        "width": "Außenbreite",
        "height": "Außenhöhe",
        "thickness": "Materialstärke",
        "kerf": "Schnittfuge (Kerf)",
    }
    values: dict[str, float | None] = {}
    for key, label in labels.items():
        raw = data.get(key, 0.0 if key == "kerf" else None)
        values[key] = _as_number(raw, key, label, errors)

    lid = data.get("lid", "offen")
    if lid not in LID_TYPES:
        errors.append({"field": "lid", "message": "Unbekannter Deckeltyp."})
    joint = data.get("joint", "stumpf")
    if joint not in JOINT_TYPES:
        errors.append(
            {"field": "joint", "message": "Dieser Verbindungstyp ist noch nicht implementiert."}
        )

    if errors:
        raise ValidationError(errors)

    params = BoxParams(
        length=values["length"],
        width=values["width"],
        height=values["height"],
        thickness=values["thickness"],
        kerf=values["kerf"],
        lid=lid,
        joint=joint,
    )
    validate_params(params)
    return params


def validate_params(p: BoxParams) -> None:
    errors: list[dict] = []
    t = p.thickness

    for key, label, value in (
        ("length", "Außenlänge", p.length),
        ("width", "Außenbreite", p.width),
        ("height", "Außenhöhe", p.height),
    ):
        if value <= 0:
            errors.append({"field": key, "message": f"{label} muss größer als 0 mm sein."})
        elif value > MAX_OUTER_MM:
            errors.append(
                {"field": key, "message": f"{label} ist größer als {MAX_OUTER_MM:g} mm – Tippfehler?"}
            )

    if t <= 0:
        errors.append({"field": "thickness", "message": "Materialstärke muss größer als 0 mm sein."})
    elif t > MAX_THICKNESS_MM:
        errors.append(
            {"field": "thickness", "message": f"Materialstärke über {MAX_THICKNESS_MM:g} mm – Tippfehler?"}
        )

    if p.kerf < 0:
        errors.append({"field": "kerf", "message": "Schnittfuge darf nicht negativ sein."})
    elif p.kerf > MAX_KERF_MM:
        errors.append(
            {"field": "kerf", "message": f"Schnittfuge über {MAX_KERF_MM:g} mm – Tippfehler?"}
        )

    if errors:
        raise ValidationError(errors)

    # Widersprüche zwischen den Maßen
    if p.length - 2 * t <= EPS:
        errors.append(
            {"field": "length", "message": "Außenlänge muss größer als 2 × Materialstärke sein."}
        )
    if p.width - 2 * t <= EPS:
        errors.append(
            {"field": "width", "message": "Außenbreite muss größer als 2 × Materialstärke sein."}
        )
    min_h_factor = 1 if p.lid == "offen" else 2
    if p.height - min_h_factor * t <= EPS:
        errors.append(
            {
                "field": "height",
                "message": f"Außenhöhe muss bei diesem Deckeltyp größer als "
                f"{min_h_factor} × Materialstärke sein.",
            }
        )
    if p.kerf >= t:
        errors.append(
            {"field": "kerf", "message": "Schnittfuge muss kleiner als die Materialstärke sein."}
        )

    if errors:
        raise ValidationError(errors)


def build_box(p: BoxParams) -> BoxDesign:
    validate_params(p)
    L, B, H, t = p.length, p.width, p.height, p.thickness
    wall_h = H - t if p.lid == "aufgelegt" else H

    panels = [
        Panel("front", "Vorderwand", L, wall_h, Box3D(0, 0, 0, L, t, wall_h)),
        Panel("back", "Rückwand", L, wall_h, Box3D(0, B - t, 0, L, B, wall_h)),
        Panel("left", "Seitenwand links", B - 2 * t, wall_h, Box3D(0, t, 0, t, B - t, wall_h)),
        Panel("right", "Seitenwand rechts", B - 2 * t, wall_h, Box3D(L - t, t, 0, L, B - t, wall_h)),
        Panel("bottom", "Boden", L - 2 * t, B - 2 * t, Box3D(t, t, 0, L - t, B - t, t)),
    ]
    if p.lid == "eingesetzt":
        panels.append(
            Panel("lid", "Deckel", L - 2 * t, B - 2 * t, Box3D(t, t, H - t, L - t, B - t, H))
        )
    elif p.lid == "aufgelegt":
        panels.append(Panel("lid", "Deckel", L, B, Box3D(0, 0, H - t, L, B, H)))

    inner_h = H - t if p.lid == "offen" else H - 2 * t
    warnings = [
        "Stumpfe Verbindungen halten nur mit Leim (oder Nägeln/Stiften).",
        "Rechnerisch geprüft – eine Probe am Laser ist noch nicht erfolgt. "
        "Bitte zuerst ein Testteil aus Restmaterial schneiden.",
    ]
    if min(L - 2 * t, B - 2 * t, inner_h) < t:
        warnings.append("Ein Innenmaß ist kleiner als die Materialstärke – sehr enge Kiste.")
    if p.kerf == 0:
        warnings.append(
            "Schnittfuge ist 0 mm: Die Teile werden um die Schnittbreite des Lasers kleiner "
            "als die Nennmaße. Den Wert am besten mit einem Testschnitt ermitteln."
        )

    design = BoxDesign(
        params=p,
        panels=panels,
        inner_length=L - 2 * t,
        inner_width=B - 2 * t,
        inner_height=inner_h,
        wall_height=wall_h,
        warnings=warnings,
    )
    problems = verify_assembly(design)
    if problems:
        # Darf bei korrekter Implementierung nie auftreten – dann lieber
        # gar kein Ergebnis als eine fehlerhafte Datei.
        raise ValidationError([{"field": None, "message": m} for m in problems])
    return design


def verify_assembly(design: BoxDesign) -> list[str]:
    """Prüft die zusammengesetzte Kiste. Gibt eine Liste von Fehlern zurück."""
    p = design.params
    L, B, H, t = p.length, p.width, p.height, p.thickness
    outer = Box3D(0, 0, 0, L, B, H)
    cavity_top = H if p.lid == "offen" else H - t
    cavity = Box3D(t, t, t, L - t, B - t, cavity_top)
    problems: list[str] = []

    for panel in design.panels:
        box = panel.placement
        if not outer.contains(box):
            problems.append(f"{panel.name} ragt über die Außenmaße hinaus.")
        if box.intersection_volume(cavity) > EPS:
            problems.append(f"{panel.name} ragt in den Innenraum.")
        dims = sorted(box.size)
        if abs(dims[0] - t) > EPS:
            problems.append(f"{panel.name} hat nicht die Materialstärke.")
        flat = sorted([panel.width, panel.height])
        if abs(flat[0] - dims[1]) > EPS or abs(flat[1] - dims[2]) > EPS:
            problems.append(f"{panel.name}: 2D-Maße passen nicht zur 3D-Lage.")

    for i, a in enumerate(design.panels):
        for b in design.panels[i + 1 :]:
            if a.placement.intersection_volume(b.placement) > EPS:
                problems.append(f"{a.name} und {b.name} überschneiden sich.")

    shell_volume = outer.volume - cavity.volume
    panel_volume = sum(pn.placement.volume for pn in design.panels)
    if abs(shell_volume - panel_volume) > 1e-6 * max(1.0, shell_volume):
        problems.append("Die Bauteile füllen die Kistenwand nicht lückenlos aus.")

    if abs(cavity.size[0] - design.inner_length) > EPS or abs(
        cavity.size[1] - design.inner_width
    ) > EPS or abs(cavity.size[2] - design.inner_height) > EPS:
        problems.append("Innenmaße stimmen nicht mit der Konstruktion überein.")
    return problems
