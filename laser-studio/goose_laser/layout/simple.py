"""Einfache Reihenanordnung von Bauteilen auf einer Materialplatte.

Achtung: Das ist KEINE optimierte Verschachtelung. Die Teile werden nach
Höhe sortiert und zeilenweise von links nach rechts gelegt
("Regal-Verfahren"). Ein platzsparender Zuschnittplan mit Drehen und
mehreren Platten folgt in Phase 5.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

EPS = 1e-6


class LayoutError(Exception):
    def __init__(self, errors: list[dict]):
        super().__init__("; ".join(e["message"] for e in errors))
        self.errors = errors


@dataclass(frozen=True)
class SheetParams:
    width: float  # nutzbare Plattenbreite (mm)
    height: float  # nutzbare Plattenhöhe (mm)
    margin: float = 5.0  # Abstand zum Plattenrand (mm)
    gap: float = 3.0  # Abstand zwischen Bauteilen (mm)


@dataclass(frozen=True)
class Item:
    key: str
    name: str
    width: float  # Zuschnittmaß inkl. Kerf
    height: float


@dataclass(frozen=True)
class PlacedItem:
    key: str
    name: str
    x: float
    y: float
    width: float
    height: float

    def overlaps(self, other: "PlacedItem", gap: float = 0.0) -> bool:
        """True, wenn sich die Rechtecke (um gap/2 vergrößert) überschneiden."""
        h = gap / 2 - EPS
        return not (
            self.x + self.width + h <= other.x - h
            or other.x + other.width + h <= self.x - h
            or self.y + self.height + h <= other.y - h
            or other.y + other.height + h <= self.y - h
        )


def parse_sheet(data: dict) -> SheetParams:
    errors: list[dict] = []
    labels = {
        "sheet_width": "Plattenbreite",
        "sheet_height": "Plattenhöhe",
        "margin": "Randabstand",
        "gap": "Teileabstand",
    }
    values = {}
    for key, label in labels.items():
        raw = data.get(key)
        try:
            value = float(raw) if not isinstance(raw, bool) else None
        except (TypeError, ValueError):
            value = None
        if value is None or not math.isfinite(value):
            errors.append({"field": key, "message": f"{label}: bitte eine Zahl eingeben."})
            continue
        values[key] = value
    if errors:
        raise LayoutError(errors)

    if values["sheet_width"] <= 0:
        errors.append({"field": "sheet_width", "message": "Plattenbreite muss größer als 0 mm sein."})
    if values["sheet_height"] <= 0:
        errors.append({"field": "sheet_height", "message": "Plattenhöhe muss größer als 0 mm sein."})
    if values["margin"] < 0:
        errors.append({"field": "margin", "message": "Randabstand darf nicht negativ sein."})
    if values["gap"] <= 0:
        errors.append(
            {
                "field": "gap",
                "message": "Teileabstand muss größer als 0 mm sein, sonst entstehen "
                "doppelte oder berührende Schnittlinien.",
            }
        )
    for key in ("sheet_width", "sheet_height"):
        if values[key] > 0 and values[key] - 2 * values["margin"] <= 0:
            errors.append(
                {"field": "margin", "message": "Randabstand ist zu groß für diese Platte."}
            )
            break
    if errors:
        raise LayoutError(errors)
    return SheetParams(
        width=values["sheet_width"],
        height=values["sheet_height"],
        margin=values["margin"],
        gap=values["gap"],
    )


def _mm(value: float) -> str:
    return f"{value:.1f}".replace(".", ",")


def shelf_layout(items: list[Item], sheet: SheetParams) -> list[PlacedItem]:
    usable_w = sheet.width - 2 * sheet.margin
    usable_h = sheet.height - 2 * sheet.margin
    errors: list[dict] = []
    for it in items:
        if it.width > usable_w + EPS or it.height > usable_h + EPS:
            errors.append(
                {
                    "field": "sheet_width",
                    "message": f"{it.name} ({_mm(it.width)} × {_mm(it.height)} mm) passt nicht "
                    f"auf die nutzbare Fläche ({_mm(usable_w)} × {_mm(usable_h)} mm).",
                }
            )
    if errors:
        raise LayoutError(errors)

    order = sorted(items, key=lambda it: (-it.height, -it.width, it.key))
    placed: list[PlacedItem] = []
    x = sheet.margin
    y = sheet.margin
    row_h = 0.0
    for it in order:
        if x > sheet.margin and x + it.width > sheet.margin + usable_w + EPS:
            y += row_h + sheet.gap
            x = sheet.margin
            row_h = 0.0
        if y + it.height > sheet.margin + usable_h + EPS:
            raise LayoutError(
                [
                    {
                        "field": "sheet_height",
                        "message": "Nicht alle Teile passen auf eine Platte. Größere Platte "
                        "wählen – mehrere Platten folgen in Phase 5.",
                    }
                ]
            )
        placed.append(PlacedItem(it.key, it.name, x, y, it.width, it.height))
        x += it.width + sheet.gap
        row_h = max(row_h, it.height)

    problems = verify_layout(placed, sheet)
    if problems:
        raise LayoutError([{"field": None, "message": m} for m in problems])
    return placed


def verify_layout(placed: list[PlacedItem], sheet: SheetParams) -> list[str]:
    """Prüft: alle Teile in der nutzbaren Fläche, keine Überschneidung."""
    problems: list[str] = []
    lo_x, lo_y = sheet.margin, sheet.margin
    hi_x, hi_y = sheet.width - sheet.margin, sheet.height - sheet.margin
    for p in placed:
        if p.x < lo_x - EPS or p.y < lo_y - EPS or p.x + p.width > hi_x + EPS or p.y + p.height > hi_y + EPS:
            problems.append(f"{p.name} liegt außerhalb der nutzbaren Plattenfläche.")
    for i, a in enumerate(placed):
        for b in placed[i + 1 :]:
            if a.overlaps(b, sheet.gap):
                problems.append(f"{a.name} und {b.name} überschneiden sich oder sind zu nah.")
    return problems
