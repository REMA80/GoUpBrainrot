import sys, cv2, numpy as np, potrace
from scipy.spatial import cKDTree
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.boundsPen import BoundsPen

SRC = "/tmp/claude-0/-home-user-GoUpBrainrot/9096847a-4aab-564d-aca4-6311e8b4f1c2/images/3.png"
OUT = "/home/user/GoUpBrainrot/designs/tuerschild-herzlich-willkommen"
SCR = "/tmp/claude-0/-home-user-GoUpBrainrot/9096847a-4aab-564d-aca4-6311e8b4f1c2/scratchpad"
BW, BH = 293.0, 150.0          # Holzplatte
WK_W, WK_MIN = float(sys.argv[1]) if len(sys.argv) > 1 else 200.0, float(sys.argv[2]) if len(sys.argv) > 2 else 2.2
WK_X, WK_TOP = 95.0, 44.0      # Lage des Schriftzugs (links, oben) auf der Platte, y nach unten
NAME = "Familie Muster"
BRIDGE = False                 # Schriftzug wird aufgeklebt: keine Verbindungsstege noetig

# ---------- Schriftzug Willkommen verdicken + vektorisieren ----------
def willkommen(width_mm, min_mm):
    UP = 4
    im = cv2.imread(SRC, cv2.IMREAD_GRAYSCALE)
    im = cv2.resize(im, None, fx=UP, fy=UP, interpolation=cv2.INTER_CUBIC)
    bw = (im < 110).astype(np.uint8)
    xs = np.nonzero(bw)[1]; mmpx = width_mm / (xs.max() - xs.min())
    dist = cv2.distanceTransform(bw, cv2.DIST_L2, 5)
    thin_half = np.percentile(dist[dist >= 1], 10)
    r = max(0, int(round(min_mm / 2 / mmpx - thin_half)))
    g = cv2.dilate(bw, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1, 2 * r + 1)))
    bridge_w = max(3, int(round(min_mm * 1.1 / mmpx)))
    while BRIDGE:
        n, lab = cv2.connectedComponents(g, connectivity=8)
        if n <= 2: break
        sizes = [(lab == i).sum() for i in range(1, n)]
        main = 1 + int(np.argmax(sizes))
        mp = np.column_stack(np.nonzero(lab == main))[::7]; tree = cKDTree(mp); best = None
        for o in range(1, n):
            if o == main: continue
            op = np.column_stack(np.nonzero(lab == o))[::7]
            d, idx = tree.query(op); j = int(np.argmin(d))
            if best is None or d[j] < best[0]: best = (d[j], op[j], mp[idx[j]])
        _, a, b = best
        cv2.line(g, (int(a[1]), int(a[0])), (int(b[1]), int(b[0])), 1, bridge_w)
    g = cv2.GaussianBlur(g.astype(np.float32), (0, 0), UP * 0.8) > 0.5
    inv = (~g).astype(np.uint8)
    n2, lab2, st2, _ = cv2.connectedComponentsWithStats(inv, 4)
    for i in range(1, n2):
        x, y, w, h, a = st2[i]
        if x > 0 and y > 0 and x + w < g.shape[1] and y + h < g.shape[0] and a * mmpx ** 2 < 4.0:
            g[lab2 == i] = True
    g = np.pad(g, 10)
    ys, xs = np.nonzero(g); gx0, gy0 = xs.min(), ys.min()
    plist = potrace.Bitmap(~g).trace(turdsize=50, alphamax=1.0, opticurve=True, opttolerance=0.2)
    def path(dx, dy):
        f = lambda p: ((p.x - gx0) * mmpx + dx, (p.y - gy0) * mmpx + dy)
        out = []
        for c in plist:
            s = f(c.start_point); d = ["M%.3f,%.3f" % s]
            for seg in c.segments:
                if seg.is_corner:
                    d.append("L%.3f,%.3f L%.3f,%.3f" % (*f(seg.c), *f(seg.end_point)))
                else:
                    d.append("C%.3f,%.3f %.3f,%.3f %.3f,%.3f" % (*f(seg.c1), *f(seg.c2), *f(seg.end_point)))
            out.append(" ".join(d) + " Z")
        return out
    dd = cv2.distanceTransform(g.astype(np.uint8), cv2.DIST_L2, 5)
    sk = dd[(dd > 0) & (cv2.dilate(dd, np.ones((3, 3))) == dd)]
    W = (xs.max() - gx0) * mmpx; H = (ys.max() - gy0) * mmpx
    n, lab, st, _ = cv2.connectedComponentsWithStats(g.astype(np.uint8), connectivity=8)
    parts = sorted([(st[i][4] * mmpx ** 2, st[i][2] * mmpx, st[i][3] * mmpx) for i in range(1, n)], reverse=True)
    print("Einzelteile (Flaeche mm2, Breite x Hoehe mm):", [(round(a), round(w), round(h)) for a, w, h in parts])
    return path, W, H, 2 * np.percentile(sk, 2) * mmpx

# ---------- Text als Pfad ----------
def text(fontfile, s, x, baseline, size, anchor="start", track=0.0):
    f = TTFont(fontfile); gs = f.getGlyphSet(); cmap = f.getBestCmap(); sc = size / f["head"].unitsPerEm
    names = [cmap[ord(c)] for c in s]; adv = [gs[n].width * sc for n in names]
    total = sum(adv) + track * size * (len(s) - 1)
    if anchor == "middle": x -= total / 2
    d = []
    for n, a in zip(names, adv):
        pen = SVGPathPen(gs, ntos=lambda v: "%.3f" % v)
        gs[n].draw(TransformPen(pen, (sc, 0, 0, -sc, x, baseline)))
        d.append(pen.getCommands()); x += a + track * size
    return " ".join(d), total

INTER = "/usr/share/fonts/opentype/inter/Inter-Light.otf"
SERIF_I = "/usr/share/fonts/truetype/liberation/LiberationSerif-Italic.ttf"

def svg(path, W, H, cut, engr, prev=False, appl=None):
    s = ['<?xml version="1.0" encoding="UTF-8"?>',
         f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.1f}mm" height="{H:.1f}mm" viewBox="0 0 {W:.3f} {H:.3f}">',
         '  <!-- ROT = Schneiden, SCHWARZ = Gravieren. Masse in mm. -->']
    if prev: s.append(f'  <rect width="{W}" height="{H}" fill="#ffffff"/>')
    if prev and appl: s.append(f'  <path fill="#d8bb8e" d="{appl[0]}"/>')
    if engr: s.append('  <g id="gravieren" fill="#000000" fill-rule="evenodd">\n' + "\n".join(f'    <path d="{d}"/>' for d in engr) + "\n  </g>")
    if prev and appl: s.append(f'  <path fill="#2b2b2b" fill-rule="evenodd" d="{appl[1]}"/>')
    if cut: s.append(f'  <g id="schneiden" fill="none" stroke="#FF0000" stroke-width="{0.35 if prev else 0.1}">\n' + "\n".join(f'    <path d="{d}"/>' for d in cut) + "\n  </g>")
    s.append("</svg>"); open(path, "w").write("\n".join(s))

path_fn, ww, wh, thin = willkommen(WK_W, WK_MIN)
m = 5.0
# 1) Holzplatte: Kontur, 4 Loecher fuer Draht, Gravur
# Platte = waagrechtes Band (Hoehe BH) aus einem Kreis mit Durchmesser BW (Ring): links und rechts rund
R = BW / 2; pcx, pcy = m + R, m + BH / 2
hx = (R * R - (BH / 2) ** 2) ** 0.5
plate = (f"M{pcx - hx:.3f},{m} H{pcx + hx:.3f} A{R},{R} 0 0,1 {pcx + hx:.3f},{m + BH} "
         f"H{pcx - hx:.3f} A{R},{R} 0 0,1 {pcx - hx:.3f},{m} Z")
holes = []
for sx in (-1, 1):
    for dy in (-60.0, 60.0):
        cx, cy, r = pcx + sx * ((R - 6) ** 2 - dy ** 2) ** 0.5, pcy + dy, 1.25
        holes.append(f"M{cx - r:.3f},{cy:.3f} a{r},{r} 0 1,0 {2 * r},0 a{r},{r} 0 1,0 {-2 * r},0 Z")
herz, hw = text(INTER, "Herzlich", m + 18, m + 40, 22)
wk_cx = m + WK_X + ww * 0.58
bei, _ = text(INTER, "bei", wk_cx, m + WK_TOP + wh + 14, 9, "middle")
fam, _ = text(INTER, NAME, wk_cx, m + WK_TOP + wh + 30, 13, "middle", 0.02)
wk_board = path_fn(m + WK_X, m + WK_TOP)
svg(f"{OUT}/platte_{int(BW)}x{int(BH)}_gravur.svg", BW + 2 * m, BH + 2 * m, [plate] + holes, [herz, bei, fam])
svg(f"{SCR}/prev_platte.svg", BW + 2 * m, BH + 2 * m, [plate] + holes, [herz, bei, fam], prev=True,
    appl=(plate, " ".join(wk_board)))
# 2) Schriftzug zum Ausschneiden (schwarzes Acryl oder Holz)
svg(f"{OUT}/willkommen_{int(WK_W)}mm_ausschneiden.svg", ww + 2 * m, wh + 2 * m, path_fn(m, m), [])
# 3) Klebeschablone: Platte mit Willkommen-Aussparung an der richtigen Stelle
svg(f"{OUT}/klebeschablone.svg", BW + 2 * m, BH + 2 * m, [plate] + wk_board, [])
# 4) Anhaenger 60 mm
R = 30.0; c = m + R
tag_cut = [f"M{c - R},{c} a{R},{R} 0 1,0 {2 * R},0 a{R},{R} 0 1,0 {-2 * R},0 Z",
           f"M{c - 2},{m + 7} a2,2 0 1,0 4,0 a2,2 0 1,0 -4,0 Z"]
t1, _ = text(INTER, "GOOSEVILLAGE DESIGN", c, c - 2, 3.6, "middle", 0.18)
t2, _ = text(SERIF_I, "handgemacht", c, c + 9, 7.5, "middle")
svg(f"{OUT}/anhaenger_60mm.svg", 2 * R + 2 * m, 2 * R + 2 * m, tag_cut, [t1, t2])
svg(f"{SCR}/prev_tag.svg", 2 * R + 2 * m, 2 * R + 2 * m, tag_cut, [t1, t2], prev=True)
print(f"Willkommen {ww:.0f} x {wh:.0f} mm, duennste Stelle ca. {thin:.1f} mm; Herzlich-Breite {hw:.0f} mm; Platten-Diagonale {np.hypot(BW, BH):.0f} mm")
