import math, os
from shapely.geometry import box, Polygon, Point, LineString
from shapely.ops import unary_union
from shapely import affinity

BASE = "/home/user/GoUpBrainrot/designs"

def rrect(x0, y0, x1, y1, r):
    return box(x0 + r, y0 + r, x1 - r, y1 - r).buffer(r, resolution=16)
def ell(cx, cy, rx, ry, rot=0):
    e = affinity.scale(Point(cx, cy).buffer(1, resolution=32), rx, ry)
    return affinity.rotate(e, rot, origin=(cx, cy))
def bez(p0, p1, p2, p3, n=24):
    return [((1-t)**3*p0[0]+3*(1-t)**2*t*p1[0]+3*(1-t)*t*t*p2[0]+t**3*p3[0],
             (1-t)**3*p0[1]+3*(1-t)**2*t*p1[1]+3*(1-t)*t*t*p2[1]+t**3*p3[1]) for t in [i/n for i in range(n+1)]]
def line(p, q, w):
    return LineString([p, q]).buffer(w / 2, cap_style=2)
def outline(g, w):
    return g.difference(g.buffer(-w))
def heart(cx, cy, s):
    pts = []
    for i in range(200):
        t = 2 * math.pi * i / 200
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2*t) - 2 * math.cos(3*t) - math.cos(4*t)
        pts.append((cx + x * s / 32, cy + y * s / 32))
    return Polygon(pts)

def paths_of(geom, f):
    geoms = geom.geoms if hasattr(geom, "geoms") else [geom]
    out = []
    for g in geoms:
        if g.is_empty: continue
        for ring in [g.exterior] + list(g.interiors):
            pts = list(ring.coords)[:-1]
            out.append("M" + " L".join("%.3f,%.3f" % f(*p) for p in pts) + " Z")
    return out

def write(path, SW, SH, cut_polys, cut_lines, engr, ghost=None, preview=False):
    f = lambda x, y: (x, SH - y)
    s = ['<?xml version="1.0" encoding="UTF-8"?>',
         f'<svg xmlns="http://www.w3.org/2000/svg" width="{SW:.1f}mm" height="{SH:.1f}mm" viewBox="0 0 {SW:.3f} {SH:.3f}">',
         '  <!-- ROT = Schneiden, SCHWARZ = Gravieren. Masse in mm. -->']
    if preview: s.append(f'  <rect width="{SW}" height="{SH}" fill="#f4e9d8"/>')
    e = unary_union(engr) if engr else None
    if e is not None and not e.is_empty:
        s.append('  <g id="gravieren" fill="#000000" fill-rule="evenodd">\n    <path d="' + " ".join(paths_of(e, f)) + '"/>\n  </g>')
    sw = 0.35 if preview else 0.1
    cl = [f'<path d="{p}"/>' for g in cut_polys for p in paths_of(g, f)]
    cl += ['<path d="M' + " L".join("%.3f,%.3f" % f(*p) for p in ln) + '"/>' for ln in cut_lines]
    s.append(f'  <g id="schneiden" fill="none" stroke="#FF0000" stroke-width="{sw}">\n    ' + "\n    ".join(cl) + "\n  </g>")
    if preview and ghost:
        for txt, x, y, size, style in ghost:
            s.append(f'  <text x="{x:.1f}" y="{SH - y:.1f}" font-family="DejaVu Serif" font-style="{style}" font-size="{size}" fill="#8a7a66" text-anchor="middle">{txt}</text>')
    s.append("</svg>")
    open(path, "w").write("\n".join(s))

# ---------------- Motive ----------------
def dove(cx, cy, s):
    """Symmetrische Taube (Heiliger Geist), Fluegel ausgebreitet. Breite ca. 68*s mm."""
    P = lambda x, y: (cx + x * s, cy + y * s)
    parts, cuts = [], []
    parts.append(ell(*P(0, 0), 5.2 * s, 11 * s))
    parts.append(Point(P(0, 12.5)).buffer(4.6 * s, resolution=32))
    parts.append(Polygon([P(-3.6, 13.6), P(-8.2, 12.2), P(-3.6, 10.8)]))
    cuts.append(Point(P(-1.4, 13.6)).buffer(0.9 * s))
    for sg in (-1, 1):
        up = bez((sg * 3, 6), (sg * 10, 17), (sg * 22, 23), (sg * 34, 23))
        low = bez((sg * 34, 23), (sg * 29, 9), (sg * 17, 0), (sg * 4, -3))
        parts.append(Polygon([P(*p) for p in up + low[1:]]))
        for i in range(1, 7):
            x, y = low[i * 4 - 2] if i * 4 - 2 < len(low) else low[-1]
            parts.append(Point(P(x, y)).buffer(2.6 * s, resolution=16))
        for k in range(3):
            cuts.append(line(P(sg * 9, 4 + k * 3.5), P(sg * 26, 12 + k * 3.5), 0.8 * s))
    tail = Polygon([P(-2.5, -8), P(-8, -22), P(8, -22), P(2.5, -8)])
    parts.append(tail)
    for x in (-6, -2, 2, 6):
        parts.append(Point(P(x, -22)).buffer(2.2 * s, resolution=16))
    for x in (-3, 3):
        cuts.append(line(P(x * 0.5, -10), P(x * 1.6, -21), 0.7 * s))
    return unary_union(parts).difference(unary_union(cuts))

def rays(cx, cy, r0, r1, n, w, a0=0, a1=360):
    out = []
    for i in range(n):
        a = math.radians(a0 + (a1 - a0) * (i + 0.5) / n)
        out.append(line((cx + r0 * math.cos(a), cy + r0 * math.sin(a)),
                        (cx + r1 * math.cos(a), cy + r1 * math.sin(a)), w))
    return out

def flames(cx, cy, s):
    def fl(x, h):
        return Polygon(bez((x - 2.6*s, cy), (x - 3.2*s, cy + h*0.5), (x + 1.2*s, cy + h*0.6), (x, cy + h)) +
                       bez((x, cy + h), (x + 1.6*s, cy + h*0.55), (x + 3.4*s, cy + h*0.4), (x + 2.6*s, cy))[1:])
    return unary_union([fl(cx - 7*s, 8*s), fl(cx, 11*s), fl(cx + 7*s, 8*s)])

def chalice(cx, cy, s):
    P = lambda x, y: (cx + x * s, cy + y * s)
    cup = Polygon([P(*p) for p in bez((-15, 24), (-15, 10), (-8, 4), (-2, 3))] +
                  [P(*p) for p in bez((2, 3), (8, 4), (15, 10), (15, 24))])
    rim = rrect(*P(-16.5, 23), *P(16.5, 26), 1.2 * s)
    stem = box(*P(-2, -10), *P(2, 4))
    knot = ell(*P(0, -3), 5 * s, 2.6 * s)
    half = bez((-2, -9), (-4, -14), (-12, -15), (-14, -18))
    foot = Polygon([P(*p) for p in half] + [P(-x, y) for x, y in reversed(half)])
    c = unary_union([cup, rim, stem, knot, foot])
    deco = [line(P(-10, 12), P(10, 12), 0.9 * s), line(P(-11.5, 16), P(11.5, 16), 0.9 * s)]
    return c.difference(unary_union(deco))

def host(cx, cy, r):
    disc = Point(cx, cy).buffer(r, resolution=48)
    cross = unary_union([box(cx - r*0.12, cy - r*0.6, cx + r*0.12, cy + r*0.6),
                         box(cx - r*0.42, cy + r*0.05, cx + r*0.42, cy + r*0.29)])
    return disc.difference(cross).difference(Point(cx, cy).buffer(r * 0.82).difference(Point(cx, cy).buffer(r * 0.76)))

def vine(cx, y, w, s=1.0):
    """Zierlinie mit Blaettchen."""
    parts = [line((cx - w/2, y), (cx + w/2, y), 0.6)]
    for k in range(-3, 4):
        if k == 0: continue
        x = cx + k * w / 8
        sgn = 1 if k % 2 else -1
        parts.append(ell(x, y + sgn * 1.6 * s, 2.4 * s, 1.0 * s, rot=sgn * 30))
    parts.append(heart(cx, y - 0.5, 4.6 * s))
    return unary_union(parts)

# ---------------- Geld-Etui (3 mm, Biegescharnier) ----------------
def geld_etui(variant):
    PW, PH, HW, R = 100.0, 140.0, 16.0, 4.0
    m = 5.0
    SW, SH = 2 * PW + HW + 2 * m, PH + 2 * m
    x_back, x_h0, x_h1, x_front = m, m + PW, m + PW + HW, m + PW + HW
    outer = rrect(m, m, m + 2 * PW + HW, m + PH, R)
    cut_lines = []
    # Biegescharnier: versetzte Schlitze, Abstand 1.5 mm, Steg 3 mm, Rand 4 mm
    sp, L, b, edge = 1.5, 20.0, 3.0, 4.0
    ncol = int(HW / sp)
    for c in range(ncol + 1):
        x = x_h0 + c * sp
        off = 0 if c % 2 == 0 else (L + b) / 2
        y = m + edge - off
        while y < m + PH - edge:
            y0, y1 = max(y, m + edge), min(y + L, m + PH - edge)
            if y1 - y0 > 3: cut_lines.append([(x, y0), (x, y1)])
            y += L + b
    # Eckenhalter fuer gefalteten Schein (Rueckseite innen), Feld 72 x 79 mm
    cx_b, cy_b = x_back + PW / 2, m + PH / 2
    fw, fh, sl = 72.0, 79.0, 12.0
    for sx in (-1, 1):
        for sy in (-1, 1):
            if sx * sy > 0: continue
            px, py = cx_b + sx * fw / 2, cy_b + sy * fh / 2
            cut_lines.append([(px - sx * 0, py - sy * sl * 0.95), (px - sx * sl * 0.95, py - sy * 0)])
    # Diagonale Eckenhalter oben-links und unten-rechts (bei Ansicht von innen gespiegelt)
    # Vorderseite: Gravur
    fx0, fx1 = x_front, x_front + PW
    fcx = (fx0 + fx1) / 2
    engr = [outline(rrect(fx0 + 6, m + 6, fx1 - 6, m + PH - 6, 3), 0.7),
            outline(rrect(fx0 + 8, m + 8, fx1 - 8, m + PH - 8, 2), 0.35)]
    ghost = []
    if variant == "firmung":
        engr += [dove(fcx, m + 88, 0.85)]
        engr += rays(fcx, m + 92, 36, 41, 11, 0.7, 35, 145)
        ghost += [("Zur Firmung", fcx, m + 56, 9, "italic")]
    else:
        engr += [chalice(fcx, m + 73, 0.95)]
        engr += [host(fcx, m + 112, 9.5)]
        engr += rays(fcx, m + 112, 12, 17, 16, 0.7)
        ghost += [("Zur Erstkommunion", fcx, m + 46, 7.5, "italic")]
    ghost += [("Name", fcx, m + (36 if variant != "firmung" else 42), 8, "italic"), ("Datum", fcx, m + 22, 5, "normal")]
    engr += [vine(fcx, m + 15, 40, 0.8)]
    return SW, SH, outer, cut_lines, engr, ghost

# ---------------- Haustier-Gedenktafel (steckbar) ----------------
def paw(cx, cy, s):
    pad = unary_union([ell(cx, cy, 9 * s, 7.4 * s), ell(cx - 5 * s, cy - 3 * s, 5 * s, 4.4 * s),
                       ell(cx + 5 * s, cy - 3 * s, 5 * s, 4.4 * s)])
    toes = [ell(cx - 11 * s, cy + 6 * s, 3.6 * s, 4.8 * s, 25), ell(cx - 4.2 * s, cy + 12 * s, 3.8 * s, 5.2 * s, 8),
            ell(cx + 4.2 * s, cy + 12 * s, 3.8 * s, 5.2 * s, -8), ell(cx + 11 * s, cy + 6 * s, 3.6 * s, 4.8 * s, -25)]
    return unary_union([pad] + toes)

def gedenktafel(t):
    TW, TB, TABW = 120.0, 90.0, 20.0
    m, gap = 5.0, 8.0
    # Tafel: Rechteck + Halbkreis oben, Zapfen unten
    plate = unary_union([box(0, 0, TW, TB), Point(TW / 2, TB).buffer(TW / 2, resolution=64)])
    plate = plate.intersection(box(0, 0, TW, TB + TW / 2))
    tabs_x = [TW * 0.25, TW * 0.75]
    plate = unary_union([plate] + [box(x - TABW / 2, -t, x + TABW / 2, 0) for x in tabs_x])
    engr = [outline(unary_union([box(5, 5, TW - 5, TB), Point(TW / 2, TB).buffer(TW / 2 - 5, resolution=64)]).intersection(box(5, 5, TW - 5, 999)), 0.8)]
    # Regenbogen-Boegen
    for k in range(3):
        r_out = 44 - k * 4.2
        band = Point(TW / 2, TB - 2).buffer(r_out, resolution=64).difference(Point(TW / 2, TB - 2).buffer(r_out - 2.4, resolution=64))
        engr.append(band.intersection(box(0, TB - 2, TW, 999)))
    engr.append(paw(TW / 2, TB + 3, 1.05))
    engr.append(vine(TW / 2, 14, 56, 0.9))
    ghost = [("Name", TW / 2, 64, 11, "italic"), ("2012 – 2026", TW / 2, 50, 6, "normal"),
             ("Für immer in unseren Herzen", TW / 2, 31, 5.2, "italic")]
    # Fuss mit Schlitzen
    BW, BD = 140.0, 45.0
    base = rrect(0, 0, BW, BD, 6)
    sc = 0.1
    by = BD / 2
    for x in tabs_x:
        bx = x + (BW - TW) / 2
        base = base.difference(box(bx - TABW / 2 - sc, by - t / 2 - sc / 2, bx + TABW / 2 + sc, by + t / 2 + sc / 2))
    # Layout
    ph = TB + TW / 2 + t
    SW = max(TW, BW) + 2 * m
    SH = m + BD + gap + ph + m
    ox_p, oy_p = m + (BW - TW) / 2, m + BD + gap + t
    tr = lambda g: affinity.translate(g, ox_p, oy_p)
    plate, engr = tr(plate), [tr(e) for e in engr]
    ghost = [(a, x + ox_p, y + oy_p, s, st) for a, x, y, s, st in ghost]
    base = affinity.translate(base, m, m)
    return SW, SH, [plate, base], engr, ghost

def render():
    out = []
    d1 = f"{BASE}/geld-etui-firmung-kommunion"; os.makedirs(d1, exist_ok=True)
    for v in ("firmung", "kommunion"):
        SW, SH, outer, cl, engr, ghost = geld_etui(v)
        write(f"{d1}/geld-etui_{v}_3mm-pappel.svg", SW, SH, [outer], cl, engr)
        write(f"{d1}/vorschau_{v}.svg", SW, SH, [outer], cl, engr, ghost, preview=True)
        # nur Motiv (Vorderseite) fuer eigene Etui-Vorlage
        write(f"{d1}/nur-motiv_{v}.svg", SW, SH, [], [], engr)
        out += [f"{d1}/vorschau_{v}.svg"]
    d2 = f"{BASE}/haustier-gedenktafel"; os.makedirs(d2, exist_ok=True)
    for t in (3.0, 5.0):
        SW, SH, polys, engr, ghost = gedenktafel(t)
        write(f"{d2}/gedenktafel_{int(t)}mm-pappel.svg", SW, SH, polys, [], engr)
        write(f"{d2}/vorschau_{int(t)}mm.svg", SW, SH, polys, [], engr, ghost, preview=True)
        out += [f"{d2}/vorschau_{int(t)}mm.svg"]
    return out

if __name__ == "__main__":
    for p in render(): print(p)
