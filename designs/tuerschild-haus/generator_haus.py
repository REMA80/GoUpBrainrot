import math
from shapely.geometry import LineString, Point, Polygon, box
from shapely.ops import unary_union
from shapely import affinity

OUT = "/home/user/GoUpBrainrot/designs/tuerschild-haus"
SCR = "/tmp/claude-0/-home-user-GoUpBrainrot/9096847a-4aab-564d-aca4-6311e8b4f1c2/scratchpad"
RING = 293.0          # Ring-Durchmesser
PW = 140.0            # Plattenbreite
LW = 5.0              # Strichstaerke Haus
R = RING / 2; m = 5.0

def heart(cx, cy, s):
    pts = []
    for i in range(200):
        t = 2 * math.pi * i / 200
        x = 16 * math.sin(t) ** 3; y = 13 * math.cos(t) - 5 * math.cos(2*t) - 2 * math.cos(3*t) - math.cos(4*t)
        pts.append((cx + x * s / 32, cy - y * s / 32))   # y nach unten
    return Polygon(pts)

def stroke(pts):
    return LineString(pts).buffer(LW / 2, cap_style="round", join_style="round", quad_segs=16)

def paths(g):
    geoms = g.geoms if hasattr(g, "geoms") else [g]
    out = []
    for p in geoms:
        for ring in [p.exterior] + list(p.interiors):
            c = list(ring.coords)[:-1]
            out.append("M" + " L".join("%.3f,%.3f" % (x + m, y + m) for x, y in c) + " Z")
    return out

# Platte: senkrechtes Band aus dem Ringkreis, oben und unten rund
hx = PW / 2; cy = R
ys = (R * R - hx * hx) ** 0.5
plate = (f"M{m},{m + cy - ys:.3f} A{R},{R} 0 0,1 {m + PW},{m + cy - ys:.3f} V{m + cy + ys:.3f} "
         f"A{R},{R} 0 0,1 {m},{m + cy + ys:.3f} Z")
def top(x): return R - (R * R - (x - hx) ** 2) ** 0.5
holes = []
for x in (hx - 45, hx + 45):
    yy = R - ((R - 6) ** 2 - (x - hx) ** 2) ** 0.5
    for y in (yy, RING - yy):
        holes.append(f"M{m + x - 1.25:.3f},{m + y:.3f} a1.25,1.25 0 1,0 2.5,0 a1.25,1.25 0 1,0 -2.5,0 Z")

def house_A():
    s = 60 / 54
    pts = [(18, 262), (18, 112), (68, 52), (92, 52 + 24 * s), (92, 62), (104, 62), (104, 52 + 36 * s), (122, 112), (122, 130)]
    return stroke(pts), []
def house_B():
    roof = stroke([(8, 121), (70, 52), (132, 121)])
    yl = 52 + (70 - 20) * 69 / 62; yr = yl
    walls = unary_union([stroke([(20, 262), (20, yl)]), stroke([(120, yr), (120, 135)])])
    return unary_union([roof, walls]), [heart(70, 86, 12)]

def house_C():
    # geschlossenes Haus mit Rundbogen-Tuer in der Grundlinie
    door = [(84, 262), (84, 238)] + [(72 + 12 * math.cos(math.radians(a)), 238 - 12 * math.sin(math.radians(a))) for a in range(0, 181, 6)] + [(60, 262)]
    pts = [(18, 262), (18, 112), (70, 52), (122, 112), (122, 262)] + door + [(18, 262)]
    return stroke(pts), []
def house_D():
    # Haus, rechte Wand endet in einem Herz
    cx, cy, s = 122, 126, 20
    hp = [(cx + 16 * math.sin(t) ** 3 * s / 32,
           cy - (13 * math.cos(t) - 5 * math.cos(2*t) - 2 * math.cos(3*t) - math.cos(4*t)) * s / 32)
          for t in [2 * math.pi * i / 160 for i in range(161)]]
    cusp = hp[0]
    house = stroke([(18, 262), (18, 112), (70, 52), (122, 112), cusp])
    heart_line = LineString(hp).buffer(LW / 2, cap_style="round", join_style="round", quad_segs=16)
    return unary_union([house, heart_line]), []

ghost = [("Herzlich", 46, 140, 14, "start"), ("Willkommen", 54, 164, 14, "start"),
         ("Anna", 122, 200, 10, "end"), ("Lukas", 122, 216, 10, "end"), ("Sophie", 122, 232, 10, "end"), ("Max", 122, 248, 10, "end")]

def svg(path, cut, engr=(), house=None, prev=False):
    W, H = PW + 2 * m, RING + 2 * m
    s = ['<?xml version="1.0" encoding="UTF-8"?>',
         f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.1f}mm" height="{H:.1f}mm" viewBox="0 0 {W:.3f} {H:.3f}">',
         '  <!-- ROT = Schneiden, SCHWARZ = Gravieren. Masse in mm. -->']
    if prev:
        s.append(f'  <rect width="{W}" height="{H}" fill="#ffffff"/>\n  <path fill="#d8bb8e" d="{plate}"/>')
    if engr: s.append('  <g id="gravieren" fill="#000000">' + "".join(f'<path d="{d}"/>' for e in engr for d in paths(e)) + "</g>")
    if prev and house is not None: s.append('  <path fill="#2b2b2b" d="' + " ".join(paths(house)) + '"/>')
    if prev:
        for t, x, y, sz, a in ghost:
            fam = "Liberation Serif" if sz > 12 else "Inter"
            st = "italic" if sz > 12 else "normal"
            s.append(f'  <text x="{x + m}" y="{y + m}" font-family="{fam}" font-style="{st}" font-weight="300" font-size="{sz}" fill="#7a6650" text-anchor="{a}">{t}</text>')
    s.append(f'  <g id="schneiden" fill="none" stroke="#FF0000" stroke-width="{0.35 if prev else 0.1}">' + "".join(f'<path d="{d}"/>' for d in cut) + "</g>")
    s.append("</svg>"); open(path, "w").write("\n".join(s))

import sys
NUR_HAUS = "--nur-haus" in sys.argv
VARIANTEN = (("C_tuer", house_C), ("D_herz", house_D)) if NUR_HAUS else (("A_schornstein", house_A), ("B_dachueberstand", house_B))
if NUR_HAUS:
    ghost = [("Herzlich", 40, 138, 13.5, "start"), ("Willkommen", 46, 160, 13.5, "start"),
             ("Anna", 110, 186, 9, "end"), ("Lukas", 110, 200, 9, "end"), ("Sophie", 110, 214, 9, "end"), ("Max", 110, 228, 9, "end")]
for tag, fn in VARIANTEN:
    h, eng = fn()
    svg(f"{OUT}/haus_{tag}_ausschneiden.svg", paths(h))
    if not NUR_HAUS:
        svg(f"{OUT}/platte_{tag}.svg", [plate] + holes, eng)
        svg(f"{OUT}/klebeschablone_{tag}.svg", [plate] + paths(h))
    svg(f"{SCR}/prev_haus_{tag}.svg", [plate] + holes, eng, h, prev=True)
    minx, miny, maxx, maxy = h.bounds
    print(tag, f"Haus {maxx - minx:.0f} x {maxy - miny:.0f} mm, Teile: {len(getattr(h, 'geoms', [h]))}")
print(f"Platte {PW:.0f} x {RING:.0f} mm (gerade Seiten {2 * ys:.0f} mm)")
