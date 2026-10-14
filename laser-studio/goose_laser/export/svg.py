"""SVG-Erzeugung für Laserdateien.

Konventionen:
* Dokumentgröße in mm (width/height mit Einheit "mm"); die viewBox hat
  dieselben Zahlenwerte, d. h. 1 SVG-Einheit = 1 mm.
* Schnittlinien: geschlossene Pfade, Kontur rot (#ff0000), keine Füllung,
  in der Gruppe id="schnitt".
* Bauteilnamen stehen nur als <title> (unsichtbar) in der Exportdatei.
  Sichtbare Beschriftungen und der Plattenrand werden nur in der
  Vorschau gezeichnet (``preview=True``), damit sie nicht versehentlich
  mitgeschnitten werden.
"""

from __future__ import annotations

from xml.sax.saxutils import escape, quoteattr

from goose_laser.layout.simple import PlacedItem, SheetParams

CUT_COLOR = "#ff0000"
CUT_STROKE_MM = 0.1


def fmt(value: float) -> str:
    """Zahl mit max. 3 Nachkommastellen, ohne überflüssige Nullen."""
    text = f"{value:.3f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def rect_path(x: float, y: float, w: float, h: float) -> str:
    """Geschlossener Rechteckpfad im Uhrzeigersinn (im SVG-Koordinatensystem)."""
    return f"M {fmt(x)} {fmt(y)} H {fmt(x + w)} V {fmt(y + h)} H {fmt(x)} Z"


def build_svg(
    placed: list[PlacedItem],
    sheet: SheetParams,
    title: str,
    description: str,
    preview: bool = False,
) -> str:
    w, h = fmt(sheet.width), fmt(sheet.height)
    lines = [
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" version="1.1" '
        f'width="{w}mm" height="{h}mm" viewBox="0 0 {w} {h}">',
        f"  <title>{escape(title)}</title>",
        f"  <desc>{escape(description)}</desc>",
    ]
    if preview:
        lines.append(
            f'  <g id="vorschau-platte"><rect x="0" y="0" width="{w}" height="{h}" '
            f'fill="#f3e6cf" stroke="#8a6d3b" stroke-width="0.5"/>'
            f'<rect x="{fmt(sheet.margin)}" y="{fmt(sheet.margin)}" '
            f'width="{fmt(sheet.width - 2 * sheet.margin)}" '
            f'height="{fmt(sheet.height - 2 * sheet.margin)}" fill="none" '
            f'stroke="#8a6d3b" stroke-width="0.3" stroke-dasharray="3 2"/></g>'
        )
    stroke_w = 0.4 if preview else CUT_STROKE_MM
    lines.append(
        f'  <g id="schnitt" fill="none" stroke="{CUT_COLOR}" stroke-width="{fmt(stroke_w)}">'
    )
    for p in placed:
        lines.append(
            f"    <path id={quoteattr('teil-' + p.key)} d=\"{rect_path(p.x, p.y, p.width, p.height)}\">"
            f"<title>{escape(p.name)}</title></path>"
        )
    lines.append("  </g>")
    if preview:
        lines.append('  <g id="vorschau-beschriftung" fill="#333" font-family="sans-serif">')
        for p in placed:
            size = max(2.5, min(10.0, p.width / 10, p.height / 4))
            lines.append(
                f'    <text x="{fmt(p.x + p.width / 2)}" y="{fmt(p.y + p.height / 2)}" '
                f'font-size="{fmt(size)}" text-anchor="middle" dominant-baseline="middle">'
                f"{escape(p.name)}</text>"
            )
        lines.append("  </g>")
    lines.append("</svg>")
    return "\n".join(lines) + "\n"
