import sys, math, importlib.util
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from shapely.geometry import Point
from shapely.ops import unary_union
from shapely import affinity

SCR = "/tmp/claude-0/-home-user-GoUpBrainrot/9096847a-4aab-564d-aca4-6311e8b4f1c2/scratchpad"
spec = importlib.util.spec_from_file_location("haus", f"{SCR}/haus.py")
sys.argv_backup = sys.argv; sys.argv = ["haus.py", "--nur-haus"]
H = importlib.util.module_from_spec(spec); spec.loader.exec_module(H)
sys.argv = sys.argv_backup

out_svg, out_prev = sys.argv[1], sys.argv[2]
names = sys.argv[3].split(",")          # letzter Name = Haustier (bekommt Pfote)
m, PW, RING = H.m, H.PW, H.RING
FONT = TTFont("/usr/share/fonts/opentype/inter/Inter-Light.otf")
gs = FONT.getGlyphSet(); cmap = FONT.getBestCmap(); upm = FONT["head"].unitsPerEm
SIZE, LEAD = 8.0, 12.0
RIGHT = 122 + H.LW / 2                  # Aussenkante rechte Hauswand (Variante F)
BASE0 = 196.0                           # Grundlinie erster Name

def text_path(s, x_right, base):
    sc = SIZE / upm
    w = sum(gs[cmap[ord(c)]].width for c in s) * sc
    x = x_right - w; d = []
    for c in s:
        n = cmap[ord(c)]; pen = SVGPathPen(gs, ntos=lambda v: "%.3f" % v)
        gs[n].draw(TransformPen(pen, (sc, 0, 0, -sc, x + m, base + m))); d.append(pen.getCommands())
        x += gs[n].width * sc
    return " ".join(d), w

def paw(cx, cy, s):   # y nach unten, Zehen oben
    E = lambda x, y, rx, ry, rot=0: affinity.rotate(affinity.scale(Point(cx + x * s, cy - y * s).buffer(1, quad_segs=24), rx * s, ry * s), -rot, origin=(cx + x * s, cy - y * s))
    pad = unary_union([E(0, 0, 9, 7.4), E(-5, -3, 5, 4.4), E(5, -3, 5, 4.4)])
    toes = [E(-11, 6, 3.6, 4.8, 25), E(-4.2, 12, 3.8, 5.2, 8), E(4.2, 12, 3.8, 5.2, -8), E(11, 6, 3.6, 4.8, -25)]
    return unary_union([pad] + toes)

engr = []
for i, n in enumerate(names):
    base = BASE0 + i * LEAD
    d, w = text_path(n, RIGHT, base); engr.append(d)
    if i == len(names) - 1:
        cap = 0.727 * SIZE                       # Versalhoehe Inter
        s = cap / 25.0
        p = paw(RIGHT - w - 2.2 - 14.6 * s, base - cap / 2 + 1.2 * s, s)
        engr.append(" ".join(H.paths(p)))

def write(path, prev):
    W, Hh = PW + 2 * m, RING + 2 * m
    s = ['<?xml version="1.0" encoding="UTF-8"?>',
         f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.1f}mm" height="{Hh:.1f}mm" viewBox="0 0 {W:.3f} {Hh:.3f}">',
         '  <!-- ROT = Schneiden (Platte + Loecher), SCHWARZ = Gravieren (Namen + Pfote). "Herzlich Willkommen" in eigener Schrift ergaenzen. -->']
    if prev:
        h, _ = H.house_F()
        s.append(f'  <rect width="{W}" height="{Hh}" fill="#ffffff"/>\n  <path fill="#d8bb8e" d="{H.plate}"/>')
        s.append('  <path fill="#2b2b2b" d="' + " ".join(H.paths(h)) + '"/>')
        s.append(f'  <text x="{40 + m}" y="{122 + m}" font-family="Liberation Serif" font-style="italic" font-size="14" fill="#7a6650">Herzlich</text>')
        s.append(f'  <text x="{46 + m}" y="{161 + m}" font-family="Liberation Serif" font-style="italic" font-size="14" fill="#7a6650">Willkommen</text>')
    s.append('  <g id="gravieren" fill="#000000" fill-rule="nonzero">' + "".join(f'<path d="{d}"/>' for d in engr) + "</g>")
    s.append(f'  <g id="schneiden" fill="none" stroke="#FF0000" stroke-width="{0.35 if prev else 0.1}"><path d="{H.plate}"/>' + "".join(f'<path d="{d}"/>' for d in H.holes) + "</g>")
    s.append("</svg>"); open(path, "w").write("\n".join(s))
write(out_svg, False); write(out_prev, True)
print("Namen rechtsbuendig an x =", RIGHT, "mm; Grundlinien", [BASE0 + i * LEAD for i in range(len(names))])
