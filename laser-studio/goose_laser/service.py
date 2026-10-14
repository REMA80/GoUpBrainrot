"""Anwendungslogik ohne Oberfläche: Eingabe -> Konstruktion -> Anordnung -> SVG.

Diese Schicht wird vom lokalen Server benutzt und kann später unverändert
hinter einer Web-API laufen.
"""

from __future__ import annotations

from goose_laser.export.svg import build_svg, fmt
from goose_laser.geometry.box import JOINT_TYPES, LID_TYPES, ValidationError, build_box, parse_params
from goose_laser.geometry.outline import bbox
from goose_laser.layout.simple import Item, LayoutError, parse_sheet, shelf_layout


class InputError(Exception):
    def __init__(self, errors: list[dict]):
        super().__init__("; ".join(e["message"] for e in errors))
        self.errors = errors


def _design_and_layout(data: dict):
    errors: list[dict] = []
    design = sheet = None
    try:
        params = parse_params(data)
        design = build_box(params)
    except ValidationError as exc:
        errors.extend(exc.errors)
    try:
        sheet = parse_sheet(data)
    except LayoutError as exc:
        errors.extend(exc.errors)
    if errors:
        raise InputError(errors)

    items = []
    shapes = {}
    for panel in design.panels:
        u0, v0, u1, v1 = bbox(panel.cut_loops)
        # Zeichenebene (v nach oben) -> Platte (y nach unten), Ursprung links oben
        shapes[panel.key] = [[(u - u0, v1 - v) for u, v in loop] for loop in panel.cut_loops]
        items.append(Item(panel.key, panel.name, u1 - u0, v1 - v0))
    try:
        placed = shelf_layout(items, sheet)
    except LayoutError as exc:
        raise InputError(exc.errors) from exc
    return design, sheet, placed, shapes


def _title(design) -> str:
    p = design.params
    return f"Kiste {fmt(p.length)} x {fmt(p.width)} x {fmt(p.height)} mm, Material {fmt(p.thickness)} mm"


def _description(design) -> str:
    p = design.params
    joint = JOINT_TYPES[p.joint]
    if p.joint == "fingerzinken":
        joint += f" (Ziel {fmt(p.finger_width)} mm, Spiel {fmt(p.clearance)} mm)"
    return (
        "Goose Village Laser Studio. Rote Linien = Schnitt. "
        f"Verbindung: {joint}, Deckel: {LID_TYPES[p.lid]}, Kerf: {fmt(p.kerf)} mm. "
        "Rechnerisch geprüft, nicht am Laser getestet."
    )


def calculate_box(data: dict) -> dict:
    design, sheet, placed, shapes = _design_and_layout(data)
    result = design.to_dict()
    result["layout"] = {
        "sheet": {
            "width": sheet.width,
            "height": sheet.height,
            "margin": sheet.margin,
            "gap": sheet.gap,
        },
        "placed": [
            {"key": p.key, "name": p.name, "x": p.x, "y": p.y, "width": p.width, "height": p.height}
            for p in placed
        ],
        "method": "Einfache Reihenanordnung (nicht optimiert)",
    }
    result["preview_svg"] = build_svg(
        placed, sheet, _title(design), _description(design), preview=True, shapes=shapes
    )
    return result


def export_box_svg(data: dict) -> tuple[str, str]:
    """Liefert (Dateiname, SVG-Text). Wirft InputError bei fehlerhafter Konstruktion."""
    design, sheet, placed, shapes = _design_and_layout(data)
    p = design.params
    stem = (
        f"kiste_{fmt(p.length)}x{fmt(p.width)}x{fmt(p.height)}_t{fmt(p.thickness)}"
        f"_{p.joint}_{p.lid}"
    )
    filename = stem.replace(".", ",") + ".svg"
    svg = build_svg(placed, sheet, _title(design), _description(design), preview=False, shapes=shapes)
    return filename, svg
