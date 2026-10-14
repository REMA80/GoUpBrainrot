"""Kistenkonstrukteur: stumpfe Verbindungen und Fingerzinken.

Koordinaten in mm: x = Länge, y = Breite, z = Höhe. Die Kiste belegt den
Quader [0, L] x [0, B] x [0, H]. Jedes Bauteil wird als Menge
achsparalleler 3D-Quader beschrieben. ``verify_assembly`` beweist damit
rechnerisch, dass die Teile zusammenpassen: alle Quader liegen in der
Außenkontur, keiner ragt in den Innenraum, keine zwei überschneiden sich,
und das Gesamtvolumen entspricht exakt der Kistenwand (abzüglich der
bewusst eingestellten Passungsluft).

Stumpfe Verbindung
------------------
* Vorder- und Rückwand: volle Außenlänge L.
* Seitenwände: zwischen Vorder- und Rückwand (B - 2t).
* Boden: zwischen allen vier Wänden eingesetzt ((L - 2t) x (B - 2t)).

Fingerzinken
------------
Jede Kante zwischen zwei Platten wird in eine ungerade Anzahl gleich
breiter Abschnitte (mindestens 3) geteilt; die Abschnitte gehören
abwechselnd der einen und der anderen Platte.
* Senkrechte Kanten: Vorder-/Rückwand besitzen die Endabschnitte.
* Boden-/Deckelkanten: die Wände besitzen die Endabschnitte, Boden und
  Deckel greifen mit ihren Zinken in die Wände.
* Die Eckwürfel (t x t x t) gehören zu Vorder- bzw. Rückwand.
* Passungsluft ("Spiel") c: Jede Zinke wird an ihren inneren Flanken um
  c/4 schmaler. Zwischen einer Zinke und ihrem Schlitz bleibt so
  insgesamt c Luft (c/2 je Seite).

Deckelvarianten
---------------
* "offen":       kein Deckel, Wandhöhe = H
* "eingesetzt":  Deckel wie der Boden (stumpf: eingesetzt; Zinken: mit
                 Zinken verbunden -> geschlossene Kiste), Wandhöhe = H
* "aufgelegt":   loser Deckel L x B auf den Wänden, Wandhöhe = H - t
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from goose_laser.geometry.outline import (
    bbox,
    find_self_intersections,
    offset_loop,
    signed_area,
    union_loops,
)

EPS = 1e-6

LID_TYPES = {
    "offen": "Offen (ohne Deckel)",
    "eingesetzt": "Deckel wie Boden (geschlossene Kiste)",
    "aufgelegt": "Deckel aufgelegt (volle Außenmaße)",
}

JOINT_TYPES = {
    "stumpf": "Stumpfe Verbindung (verleimen)",
    "fingerzinken": "Fingerzinken",
}

# Plausibilitätsgrenzen – keine Materialwerte, nur Schutz vor Tippfehlern.
MAX_OUTER_MM = 3000.0
MAX_THICKNESS_MM = 50.0
MAX_KERF_MM = 2.0
MIN_FINGER_MM = 1.0
MAX_CLEARANCE_MM = 1.0
MIN_SEGMENTS = 3
# Obergrenze, damit Berechnung und Prüfung in kurzer Zeit fertig werden.
MAX_SEGMENTS = 301

X, Y, Z = 0, 1, 2


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

    @staticmethod
    def of(x: tuple[float, float], y: tuple[float, float], z: tuple[float, float]) -> "Box3D":
        return Box3D(x[0], y[0], z[0], x[1], y[1], z[1])

    def lo(self, axis: int) -> float:
        return (self.x0, self.y0, self.z0)[axis]

    def hi(self, axis: int) -> float:
        return (self.x1, self.y1, self.z1)[axis]

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
    finger_width: float = 10.0  # Ziel-Zinkenbreite (mm), nur Fingerzinken
    clearance: float = 0.0  # Passungsluft je Zinke (mm), nur Fingerzinken


@dataclass
class Panel:
    """Ein Bauteil als Menge von 3D-Quadern in einer Plattenebene.

    ``u_axis``/``v_axis`` sind die Achsen der Zeichenebene, ``normal_axis``
    die Dickenrichtung. ``loops`` (Nennkontur) und ``cut_loops`` (um
    Kerf/2 versetzt) werden in ``build_box`` berechnet; v zeigt nach oben.
    """

    key: str
    name: str
    boxes: list[Box3D]
    u_axis: int
    v_axis: int
    normal_axis: int
    loops: list = field(default_factory=list)
    cut_loops: list = field(default_factory=list)

    def rects2d(self) -> list[tuple[float, float, float, float]]:
        return [
            (b.lo(self.u_axis), b.lo(self.v_axis), b.hi(self.u_axis), b.hi(self.v_axis))
            for b in self.boxes
        ]

    @property
    def width(self) -> float:
        r = self.rects2d()
        return max(x[2] for x in r) - min(x[0] for x in r)

    @property
    def height(self) -> float:
        r = self.rects2d()
        return max(x[3] for x in r) - min(x[1] for x in r)

    def cut_size(self, kerf: float) -> tuple[float, float]:
        """Abmessungen der Schnittlinie (Nennmaß + Kerf).

        Der Laser trägt auf jeder Seite der Linie etwa kerf/2 ab. Liegt die
        Linie kerf/2 außerhalb der Nennkontur, hat das fertige Teil das
        Nennmaß.
        """
        return (self.width + kerf, self.height + kerf)


@dataclass
class EdgeInfo:
    name: str
    length: float
    segments: int
    segment_width: float

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "length": self.length,
            "segments": self.segments,
            "segment_width": self.segment_width,
        }


@dataclass
class BoxDesign:
    params: BoxParams
    panels: list[Panel]
    inner_length: float
    inner_width: float
    inner_height: float
    wall_height: float
    edges: list[EdgeInfo] = field(default_factory=list)
    expected_gap_volume: float = 0.0
    warnings: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        p = self.params
        return {
            "params": {
                "length": p.length,
                "width": p.width,
                "height": p.height,
                "thickness": p.thickness,
                "kerf": p.kerf,
                "lid": p.lid,
                "joint": p.joint,
                "finger_width": p.finger_width,
                "clearance": p.clearance,
            },
            "inner": {
                "length": self.inner_length,
                "width": self.inner_width,
                "height": self.inner_height,
            },
            "wall_height": self.wall_height,
            "edges": [e.to_dict() for e in self.edges],
            "panels": [
                {
                    "key": pn.key,
                    "name": pn.name,
                    "width": pn.width,
                    "height": pn.height,
                    "cut_width": pn.cut_size(p.kerf)[0],
                    "cut_height": pn.cut_size(p.kerf)[1],
                }
                for pn in self.panels
            ],
            "warnings": list(self.warnings),
        }


# ---------------------------------------------------------------------------
# Eingaben lesen und prüfen
# ---------------------------------------------------------------------------

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

    joint = data.get("joint", "stumpf")
    if joint not in JOINT_TYPES:
        errors.append(
            {"field": "joint", "message": "Dieser Verbindungstyp ist noch nicht implementiert."}
        )
    lid = data.get("lid", "offen")
    if lid not in LID_TYPES:
        errors.append({"field": "lid", "message": "Unbekannter Deckeltyp."})

    labels = {
        "length": "Außenlänge",
        "width": "Außenbreite",
        "height": "Außenhöhe",
        "thickness": "Materialstärke",
        "kerf": "Schnittfuge (Kerf)",
    }
    defaults = {"kerf": 0.0}
    if joint == "fingerzinken":
        labels["finger_width"] = "Zinkenbreite"
        labels["clearance"] = "Spiel"
        defaults["clearance"] = 0.0
    values: dict[str, float | None] = {}
    for key, label in labels.items():
        values[key] = _as_number(data.get(key, defaults.get(key)), key, label, errors)

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
        finger_width=values.get("finger_width", BoxParams.finger_width),
        clearance=values.get("clearance", BoxParams.clearance),
    )
    validate_params(params)
    return params


def _mm(value: float) -> str:
    """Zahl für Meldungen im deutschen Format (Komma, max. 2 Nachkommastellen)."""
    return f"{value:.2f}".rstrip("0").rstrip(".").replace(".", ",")


def _finger_segments(length: float, target: float) -> int:
    """Größte ungerade Anzahl Abschnitte mit Breite >= Zielbreite."""
    n = int(math.floor(length / target + 1e-9))
    if n % 2 == 0:
        n -= 1
    return n


def _edge_lengths(p: BoxParams) -> list[tuple[str, str, float]]:
    """(Schlüssel, Name, Länge) der verzinkten Kanten."""
    t = p.thickness
    v_top = p.height if p.lid == "offen" else p.height - t
    edges = [
        ("vertical", "Senkrechte Ecken", v_top - t),
        ("length", "Boden – Vorder-/Rückwand", p.length - 2 * t),
        ("width", "Boden – Seitenwände", p.width - 2 * t),
    ]
    return edges


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

    if p.joint == "fingerzinken":
        if p.finger_width < MIN_FINGER_MM:
            errors.append(
                {"field": "finger_width", "message": f"Zinkenbreite muss mindestens {MIN_FINGER_MM:g} mm sein."}
            )
        elif p.finger_width > MAX_OUTER_MM:
            errors.append({"field": "finger_width", "message": "Zinkenbreite ist unplausibel groß."})
        if p.clearance < 0:
            errors.append(
                {
                    "field": "clearance",
                    "message": "Spiel darf nicht negativ sein. Für einen strammeren Sitz "
                    "den Kerf-Wert etwas erhöhen.",
                }
            )
        elif p.clearance > MAX_CLEARANCE_MM:
            errors.append(
                {"field": "clearance", "message": f"Spiel über {MAX_CLEARANCE_MM:g} mm – Tippfehler?"}
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

    if p.joint == "fingerzinken":
        for _key, name, length in _edge_lengths(p):
            n = _finger_segments(length, p.finger_width)
            if n < MIN_SEGMENTS:
                errors.append(
                    {
                        "field": "finger_width",
                        "message": f"Kante „{name}“ ({_mm(length)} mm) ist zu kurz für Zinken mit "
                        f"{_mm(p.finger_width)} mm Breite (mindestens {MIN_SEGMENTS} Abschnitte nötig). "
                        "Zinkenbreite verkleinern.",
                    }
                )
                continue
            if n > MAX_SEGMENTS:
                errors.append(
                    {
                        "field": "finger_width",
                        "message": f"Kante „{name}“ hätte {n} Zinkenabschnitte (höchstens "
                        f"{MAX_SEGMENTS} möglich). Zinkenbreite vergrößern.",
                    }
                )
                continue
            seg_w = length / n
            if seg_w - p.clearance / 2 < MIN_FINGER_MM:
                errors.append(
                    {
                        "field": "clearance",
                        "message": f"Kante „{name}“: Mit diesem Spiel bleiben die Zinken schmaler "
                        f"als {_mm(MIN_FINGER_MM)} mm.",
                    }
                )
    if errors:
        raise ValidationError(errors)


# ---------------------------------------------------------------------------
# Konstruktion
# ---------------------------------------------------------------------------

def _segments(a: float, b: float, n: int, clearance: float) -> list[tuple[int, float, float]]:
    """Teilt [a, b] in n gleiche Abschnitte; innere Flanken um c/4 eingerückt."""
    w = (b - a) / n
    out = []
    for i in range(n):
        s0 = a + i * w
        s1 = a + (i + 1) * w
        if i > 0:
            s0 += clearance / 4
        if i < n - 1:
            s1 -= clearance / 4
        out.append((i, s0, s1))
    return out


def _butt_panels(p: BoxParams, wall_h: float) -> list[Panel]:
    L, B, H, t = p.length, p.width, p.height, p.thickness
    panels = [
        Panel("front", "Vorderwand", [Box3D.of((0, L), (0, t), (0, wall_h))], X, Z, Y),
        Panel("back", "Rückwand", [Box3D.of((0, L), (B - t, B), (0, wall_h))], X, Z, Y),
        Panel("left", "Seitenwand links", [Box3D.of((0, t), (t, B - t), (0, wall_h))], Y, Z, X),
        Panel("right", "Seitenwand rechts", [Box3D.of((L - t, L), (t, B - t), (0, wall_h))], Y, Z, X),
        Panel("bottom", "Boden", [Box3D.of((t, L - t), (t, B - t), (0, t))], X, Y, Z),
    ]
    if p.lid == "eingesetzt":
        panels.append(Panel("lid", "Deckel", [Box3D.of((t, L - t), (t, B - t), (H - t, H))], X, Y, Z))
    return panels


def _finger_panels(p: BoxParams, wall_h: float) -> tuple[list[Panel], list[EdgeInfo], int]:
    L, B, H, t, c = p.length, p.width, p.height, p.thickness, p.clearance
    top_fingered = p.lid == "eingesetzt"
    # Oberkante der senkrechten Zinkenleiste und des Wand-Innenbereichs
    v_top = H - t if top_fingered else wall_h

    n_v = _finger_segments(v_top - t, p.finger_width)
    n_x = _finger_segments(L - 2 * t, p.finger_width)
    n_y = _finger_segments(B - 2 * t, p.finger_width)
    seg_v = _segments(t, v_top, n_v, c)
    seg_x = _segments(t, L - t, n_x, c)
    seg_y = _segments(t, B - t, n_y, c)

    z_strips = [(0, t)] + ([(H - t, H)] if top_fingered else [])

    def long_wall(key: str, name: str, yr: tuple[float, float]) -> Panel:
        boxes = [Box3D.of((t, L - t), yr, (t, v_top))]
        for xr in ((0, t), (L - t, L)):
            boxes += [Box3D.of(xr, yr, (s0, s1)) for i, s0, s1 in seg_v if i % 2 == 0]
            boxes += [Box3D.of(xr, yr, zr) for zr in z_strips]  # Eckwürfel
        for zr in z_strips:
            boxes += [Box3D.of((s0, s1), yr, zr) for i, s0, s1 in seg_x if i % 2 == 0]
        return Panel(key, name, boxes, X, Z, Y)

    def side_wall(key: str, name: str, xr: tuple[float, float]) -> Panel:
        boxes = [Box3D.of(xr, (t, B - t), (t, v_top))]
        for yr in ((0, t), (B - t, B)):
            boxes += [Box3D.of(xr, yr, (s0, s1)) for i, s0, s1 in seg_v if i % 2 == 1]
        for zr in z_strips:
            boxes += [Box3D.of(xr, (s0, s1), zr) for i, s0, s1 in seg_y if i % 2 == 0]
        return Panel(key, name, boxes, Y, Z, X)

    def plate(key: str, name: str, zr: tuple[float, float]) -> Panel:
        boxes = [Box3D.of((t, L - t), (t, B - t), zr)]
        for yr in ((0, t), (B - t, B)):
            boxes += [Box3D.of((s0, s1), yr, zr) for i, s0, s1 in seg_x if i % 2 == 1]
        for xr in ((0, t), (L - t, L)):
            boxes += [Box3D.of(xr, (s0, s1), zr) for i, s0, s1 in seg_y if i % 2 == 1]
        return Panel(key, name, boxes, X, Y, Z)

    panels = [
        long_wall("front", "Vorderwand", (0, t)),
        long_wall("back", "Rückwand", (B - t, B)),
        side_wall("left", "Seitenwand links", (0, t)),
        side_wall("right", "Seitenwand rechts", (L - t, L)),
        plate("bottom", "Boden", (0, t)),
    ]
    if top_fingered:
        panels.append(plate("lid", "Deckel", (H - t, H)))

    edges = [
        EdgeInfo("Senkrechte Ecken", v_top - t, n_v, (v_top - t) / n_v),
        EdgeInfo("Boden – Vorder-/Rückwand", L - 2 * t, n_x, (L - 2 * t) / n_x),
        EdgeInfo("Boden – Seitenwände", B - 2 * t, n_y, (B - 2 * t) / n_y),
    ]
    if top_fingered:
        edges += [
            EdgeInfo("Deckel – Vorder-/Rückwand", L - 2 * t, n_x, (L - 2 * t) / n_x),
            EdgeInfo("Deckel – Seitenwände", B - 2 * t, n_y, (B - 2 * t) / n_y),
        ]
    # Anzahl der inneren Abschnittsgrenzen (dort entsteht die Passungsluft)
    boundaries = 4 * (n_v - 1) + len(z_strips) * (2 * (n_x - 1) + 2 * (n_y - 1))
    return panels, edges, boundaries


def build_box(p: BoxParams) -> BoxDesign:
    validate_params(p)
    L, B, H, t = p.length, p.width, p.height, p.thickness
    wall_h = H - t if p.lid == "aufgelegt" else H

    edges: list[EdgeInfo] = []
    gap_volume = 0.0
    if p.joint == "fingerzinken":
        panels, edges, boundaries = _finger_panels(p, wall_h)
        gap_volume = boundaries * (p.clearance / 2) * t * t
    else:
        panels = _butt_panels(p, wall_h)
    if p.lid == "aufgelegt":
        panels.append(Panel("lid", "Deckel", [Box3D.of((0, L), (0, B), (H - t, H))], X, Y, Z))

    inner_h = H - t if p.lid == "offen" else H - 2 * t
    warnings: list[str] = []
    if p.joint == "stumpf":
        warnings.append("Stumpfe Verbindungen halten nur mit Leim (oder Nägeln/Stiften).")
    else:
        warnings.append(
            "Die Zinkentiefe entspricht der eingegebenen Materialstärke. Bitte die tatsächliche "
            "Stärke messen – sie kann vom Nennmaß abweichen."
        )
        if any(e.segment_width < t for e in edges):
            warnings.append(
                "Mindestens eine Zinke ist schmaler als die Materialstärke und kann leicht abbrechen."
            )
        if p.clearance == 0:
            warnings.append(
                "Spiel ist 0 mm: Die Zinken passen nur dann, wenn der Kerf-Wert stimmt. "
                "Sitzen sie im Test zu stramm, das Spiel etwas erhöhen."
            )
    warnings.append(
        "Rechnerisch geprüft – eine Probe am Laser ist noch nicht erfolgt. "
        "Bitte zuerst ein Testteil aus Restmaterial schneiden."
    )
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
        edges=edges,
        expected_gap_volume=gap_volume,
        warnings=warnings,
    )
    problems = verify_assembly(design)
    if problems:
        # Darf bei korrekter Implementierung nie auftreten – dann lieber
        # gar kein Ergebnis als eine fehlerhafte Datei.
        raise ValidationError([{"field": None, "message": m} for m in problems])

    errors = _build_outlines(design)
    if errors:
        raise ValidationError(errors)
    return design


def _build_outlines(design: BoxDesign) -> list[dict]:
    """Berechnet Nenn- und Schnittkonturen und prüft sie."""
    half_kerf = design.params.kerf / 2
    errors: list[dict] = []
    for panel in design.panels:
        loops = union_loops(panel.rects2d())
        outer = [lp for lp in loops if signed_area(lp) > 0]
        if len(outer) != 1:
            errors.append({"field": None, "message": f"{panel.name} zerfällt in mehrere Stücke."})
            continue
        cut = [offset_loop(lp, half_kerf) for lp in loops]
        flipped = any(
            (signed_area(a) > 0) != (signed_area(b) > 0) or abs(signed_area(b)) < EPS
            for a, b in zip(loops, cut)
        )
        if flipped or find_self_intersections(cut):
            errors.append(
                {
                    "field": "kerf",
                    "message": f"{panel.name}: Mit dieser Schnittfuge werden Schlitze zu schmal oder "
                    "Konturen überschneiden sich. Kerf verkleinern oder Zinken verbreitern.",
                }
            )
            continue
        bx = bbox(cut)
        expected = panel.cut_size(design.params.kerf)
        if abs((bx[2] - bx[0]) - expected[0]) > EPS or abs((bx[3] - bx[1]) - expected[1]) > EPS:
            errors.append({"field": None, "message": f"{panel.name}: Schnittkontur hat falsche Maße."})
            continue
        panel.loops = loops
        panel.cut_loops = cut
    return errors


def verify_assembly(design: BoxDesign) -> list[str]:
    """Prüft die zusammengesetzte Kiste. Gibt eine Liste von Fehlern zurück."""
    p = design.params
    L, B, H, t = p.length, p.width, p.height, p.thickness
    outer = Box3D(0, 0, 0, L, B, H)
    cavity_top = H if p.lid == "offen" else H - t
    cavity = Box3D(t, t, t, L - t, B - t, cavity_top)
    problems: list[str] = []

    all_boxes: list[tuple[Panel, Box3D]] = []
    for panel in design.panels:
        if not panel.boxes:
            problems.append(f"{panel.name} ist leer.")
            continue
        n_ax = panel.normal_axis
        lo, hi = panel.boxes[0].lo(n_ax), panel.boxes[0].hi(n_ax)
        if abs(hi - lo - t) > EPS:
            problems.append(f"{panel.name} hat nicht die Materialstärke.")
        for box in panel.boxes:
            if abs(box.lo(n_ax) - lo) > EPS or abs(box.hi(n_ax) - hi) > EPS:
                problems.append(f"{panel.name} liegt nicht in einer Ebene.")
                break
        for box in panel.boxes:
            if min(box.size) <= EPS:
                problems.append(f"{panel.name} enthält einen leeren Teilbereich.")
            if not outer.contains(box):
                problems.append(f"{panel.name} ragt über die Außenmaße hinaus.")
            if box.intersection_volume(cavity) > EPS:
                problems.append(f"{panel.name} ragt in den Innenraum.")
            all_boxes.append((panel, box))

    # Sweep entlang x: nur Quader vergleichen, deren x-Bereiche sich überlappen.
    reported: set[tuple[str, str]] = set()
    ordered = sorted(all_boxes, key=lambda pb: pb[1].x0)
    for i, (pa, a) in enumerate(ordered):
        for pb, b in ordered[i + 1 :]:
            if b.x0 >= a.x1 - EPS:
                break
            if a.intersection_volume(b) > EPS:
                names = (pa.name, pb.name)
                if names not in reported:
                    reported.add(names)
                    if pa is pb:
                        problems.append(f"{pa.name} überschneidet sich mit sich selbst.")
                    else:
                        problems.append(f"{pa.name} und {pb.name} überschneiden sich.")

    shell_volume = outer.volume - cavity.volume
    panel_volume = sum(b.volume for _, b in all_boxes)
    expected = shell_volume - design.expected_gap_volume
    if abs(expected - panel_volume) > 1e-6 * max(1.0, shell_volume):
        problems.append("Die Bauteile füllen die Kistenwand nicht lückenlos aus.")

    if (
        abs(cavity.size[0] - design.inner_length) > EPS
        or abs(cavity.size[1] - design.inner_width) > EPS
        or abs(cavity.size[2] - design.inner_height) > EPS
    ):
        problems.append("Innenmaße stimmen nicht mit der Konstruktion überein.")
    return problems
