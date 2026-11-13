import math, sys
from shapely.geometry import box, Polygon, Point, MultiPolygon
from shapely.ops import unary_union
from shapely import affinity
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

OUT = "/home/user/GoUpBrainrot/designs/sparziel-spardose"
W, H, D = 100.0, 140.0, 70.0      # Aussenmasse Breite, Hoehe, Tiefe (mm)
A = 3.0                           # Acrylstaerke
G = 3.0                           # Abstand Front-Innenseite -> Acryl
SC = 0.1                          # Spiel Acryl-Schlitze
TAB = 16.0                        # Laenge Acryl-Zapfen
FW = 10.0                         # Ziel-Fingerbreite
OV = 2.0                          # Deckel-Ueberstand
GAP = 6.0                         # Abstand Teile im Layout

def segs(L):
    n = max(3, round(L / FW))
    if n % 2 == 0: n += 1
    s = L / n
    return [(i * s, (i + 1) * s) for i in range(n)]

def panel(w, h, t, edges):
    """edges: dict bottom/top/left/right -> None|'A'|'B'. A keeps even segments, B keeps odd."""
    g = box(0, 0, w, h)
    cuts = []
    for e, kind in edges.items():
        if not kind: continue
        L = w if e in ("bottom", "top") else h
        for i, (a0, a1) in enumerate(segs(L)):
            notch = (i % 2 == 1) if kind == "A" else (i % 2 == 0)
            if not notch: continue
            if e == "bottom": cuts.append(box(a0, -1, a1, t))
            if e == "top":    cuts.append(box(a0, h - t, a1, h + 1))
            if e == "left":   cuts.append(box(-1, a0, t, a1))
            if e == "right":  cuts.append(box(w - t, a0, w + 1, a1))
    return g.difference(unary_union(cuts)) if cuts else g

def rrect(x0, y0, x1, y1, r):
    return box(x0 + r, y0 + r, x1 - r, y1 - r).buffer(r, resolution=16)

def star(cx, cy, ro, ri=None, n=5):
    ri = ri or ro * 0.42
    return Polygon([(cx + (ro if i % 2 == 0 else ri) * math.cos(math.radians(90 + i * 180 / n)),
                     cy + (ro if i % 2 == 0 else ri) * math.sin(math.radians(90 + i * 180 / n))) for i in range(2 * n)])

FONT = TTFont("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf")
def text_path(s, cx, y, size, track=0.08):
    """Text als Pfad (y-up Koordinaten), zentriert um cx, Grundlinie y."""
    gs = FONT.getGlyphSet(); cmap = FONT.getBestCmap(); upm = FONT["head"].unitsPerEm
    sc = size / upm
    names = [cmap[ord(c)] for c in s]
    adv = [gs[n].width * sc for n in names]
    total = sum(adv) + track * size * (len(s) - 1)
    x = cx - total / 2
    parts = []
    for n, a in zip(names, adv):
        parts.append((n, sc, x, y))
        x += a + track * size
    return parts

def build(t):
    P = {}
    # Front: Fenster ausgeschnitten, Skala + Text graviert
    front = panel(W, H, t, {"left": "A", "right": "A", "bottom": "A", "top": None})
    wx0, wx1 = 14.0, 68.0
    wy0, wy1 = t + 6.0, 104.0
    front = front.difference(rrect(wx0, wy0, wx1, wy1, 5))
    eng = []
    n = 20
    for i in range(n + 1):
        y = wy0 + (wy1 - wy0) * i / n
        L = 9.0 if i % 5 == 0 else (6.0 if i % 2 == 0 else 3.5)
        if i == n: continue
        eng.append(box(wx1 + 4, y - 0.35, wx1 + 4 + L, y + 0.35))
    eng.append(box(wx1 + 4, wy1 - 0.35, wx1 + 13, wy1 + 0.35))
    eng.append(star(wx1 + 20.5, wy1, 5.0))
    eng.append(box(wx1 + 4, wy0, wx1 + 4.7, wy1))  # Skala-Laengslinie
    # Namens-/Zielfeld (Rahmen) und Ueberschrift
    fy0, fy1 = 109.0, 121.0
    eng.append(rrect(14, fy0, W - 14, fy1, 3).difference(rrect(14.7, fy0 + 0.7, W - 14.7, fy1 - 0.7, 2.3)))
    P["front"] = (front, eng, [text_path("MEIN SPARZIEL", W / 2, 125.5, 7.2)])
    P["back"] = (panel(W, H, t, {"left": "A", "right": "A", "bottom": "A", "top": None}), [], [])
    # Seiten: u = Tiefe ab Front, v = Hoehe
    tabs_y = [H * 0.30, H * 0.72]
    side = panel(D, H, t, {"left": "B", "right": "B", "bottom": "A", "top": None})
    for cy in tabs_y:
        side = side.difference(box(t + G - SC / 2, cy - TAB / 2 - SC, t + G + A + SC / 2, cy + TAB / 2 + SC))
    P["side1"] = (side, [], []); P["side2"] = (side, [], [])
    # Boden: u = Breite, v = Tiefe ab Front
    tabs_x = [W * 0.30, W * 0.70]
    bottom = panel(W, D, t, {"left": "B", "right": "B", "bottom": "B", "top": "B"})
    for cx in tabs_x:
        bottom = bottom.difference(box(cx - TAB / 2 - SC, t + G - SC / 2, cx + TAB / 2 + SC, t + G + A + SC / 2))
    P["bottom"] = (bottom, [], [])
    # Deckel + Steckeinsatz (Einsatz passt zwischen Acryl und Rueckwand)
    lw, ld = W + 2 * OV, D + 2 * OV
    zc = (t + G + A + D - t) / 2
    slot = rrect(W / 2 - 15, zc - 2, W / 2 + 15, zc + 2, 1.99)
    P["lid"] = (rrect(0, 0, lw, ld, 3).difference(affinity.translate(slot, OV, OV)), [], [])
    plug = box(t, t + G + A, W - t, D - t).difference(slot)
    P["plug"] = (affinity.translate(plug, -t, -(t + G + A)), [], [])
    # Passprobe: 3 Schlitze 3.0 / 3.1 / 3.2 mm (+ Markierungspunkte)
    probe = rrect(0, 0, 54, 22, 2)
    pe = []
    for k, wd in enumerate([A, A + 0.1, A + 0.2]):
        cx = 10 + k * 17
        probe = probe.difference(box(cx - wd / 2, 4, cx + wd / 2, 4 + TAB + 0.2 - 4))
        for j in range(k + 1):
            pe.append(Point(cx - 4 + j * 4, 18.5).buffer(0.9))
    P["probe"] = (probe, pe, [])
    # Acryl-Scheibe (Frontansicht x/y)
    acr = box(t, t, W - t, H)
    for cy in tabs_y: acr = acr.union(box(0, cy - TAB / 2, W, cy + TAB / 2).intersection(box(0, 0, W, H)))
    for cx in tabs_x: acr = acr.union(box(cx - TAB / 2, 0, cx + TAB / 2, t))
    acr = acr.difference(box(0, 0, t, H).difference(unary_union([box(0, cy - TAB / 2, t, cy + TAB / 2) for cy in tabs_y])))
    acr = acr.difference(box(W - t, 0, W, H).difference(unary_union([box(W - t, cy - TAB / 2, W, cy + TAB / 2) for cy in tabs_y])))
    return P, acr

def ring_paths(geom, f):
    geoms = geom.geoms if hasattr(geom, "geoms") else [geom]
    out = []
    for g in geoms:
        for ring in [g.exterior] + list(g.interiors):
            pts = list(ring.coords)
            out.append("M" + " L".join(f"{x:.3f},{y:.3f}" for x, y in (f(*p) for p in pts[:-1])) + " Z")
    return out

def flip_path(d, dx, dy, SH):
    # fontTools path (absolute M/L/Q/C/Z) -> verschieben und y spiegeln
    import re
    toks = re.findall(r"[MLQCZ]|-?\d+\.?\d*(?:e-?\d+)?", d)
    out, nums = [], []
    def flush():
        for i in range(0, len(nums), 2):
            out.append(f"{nums[i] + dx:.3f},{SH - (nums[i + 1] + dy):.3f}")
    for tk in toks:
        if tk in "MLQCZ":
            flush(); nums.clear(); out.append(tk)
        else: nums.append(float(tk))
    flush()
    return " ".join(out)

def write_svg(path, items, SW, SH, preview=False, labels=None):
    cut, eng = [], []
    for geom, engs, texts, dx, dy in items:
        f = lambda x, y, dx=dx, dy=dy: (x + dx, SH - (y + dy))
        cut += ring_paths(geom, f)
        for e in engs: eng.append(f'<path d="{" ".join(ring_paths(e, f))}"/>')
        for tp in texts:
            gs = FONT.getGlyphSet(); d = []
            for n, sc, ox, oy in tp:
                pen = SVGPathPen(gs, ntos=lambda v: f"{v:.3f}")
                gs[n].draw(TransformPen(pen, (sc, 0, 0, -sc, ox + dx, SH - oy - dy)))
                d.append(pen.getCommands())
            eng.append(f'<path d="{" ".join(d)}"/>')
    s = ['<?xml version="1.0" encoding="UTF-8"?>',
         f'<svg xmlns="http://www.w3.org/2000/svg" width="{SW:.1f}mm" height="{SH:.1f}mm" viewBox="0 0 {SW:.3f} {SH:.3f}">',
         '  <!-- ROT = Schneiden, SCHWARZ = Gravieren. Masse in mm. -->']
    if preview: s.append(f'  <rect width="{SW}" height="{SH}" fill="#f4e9d8"/>')
    sw = 0.35 if preview else 0.1
    s.append(f'  <g id="gravieren" fill="#000000" fill-rule="evenodd">\n    ' + "\n    ".join(eng) + "\n  </g>")
    s.append(f'  <g id="schneiden" fill="none" stroke="#FF0000" stroke-width="{sw}">\n    ' +
             "\n    ".join(f'<path d="{p}"/>' for p in cut) + "\n  </g>")
    if preview and labels:
        for txt, x, y in labels:
            s.append(f'  <text x="{x:.1f}" y="{SH - y:.1f}" font-family="DejaVu Sans" font-size="4.2" fill="#1f4fa0" text-anchor="middle">{txt}</text>')
    s.append("</svg>")
    open(path, "w").write("\n".join(s))

def layout(t):
    P, acr = build(t)
    row1 = ["front", "back", "side1", "side2"]
    row2 = ["bottom", "lid", "plug", "probe"]
    names = {"front": "Front", "back": "Rueckwand", "side1": "Seite", "side2": "Seite", "bottom": "Boden",
             "lid": "Deckel", "plug": "Deckel-Einsatz", "probe": "Passprobe"}
    items, labels = [], []
    m = 5.0
    def place(keys, y0):
        x = m; hmax = 0
        for k in keys:
            g, e, tx = P[k]
            minx, miny, maxx, maxy = g.bounds
            dx, dy = x - minx, y0 - miny
            items.append((g, e, tx, dx, dy))
            labels.append((names[k], x + (maxx - minx) / 2, y0 - 6))
            x += (maxx - minx) + GAP; hmax = max(hmax, maxy - miny)
        return x - GAP + m, hmax
    w2, h2 = place(row2, m + 8)
    w1, h1 = place(row1, m + 8 + h2 + GAP + 8)
    SW = max(w1, w2); SH = m + 8 + h2 + GAP + 8 + h1 + m
    tag = f"{int(t)}mm-pappel_3mm-acryl"
    write_svg(f"{OUT}/spardose_{tag}_HOLZ.svg", items, SW, SH)
    write_svg(f"{OUT}/vorschau_{tag}_holz.svg", items, SW, SH, preview=True, labels=labels)
    aw, ah = W + 2 * m, H + 2 * m
    write_svg(f"{OUT}/spardose_{tag}_ACRYL.svg", [(acr, [], [], m, m)], aw, ah)
    print(tag, f"Holz-Layout {SW:.0f} x {SH:.0f} mm, Acryl {aw:.0f} x {ah:.0f} mm")
    return P, acr

for t in (3.0, 5.0):
    layout(t)
