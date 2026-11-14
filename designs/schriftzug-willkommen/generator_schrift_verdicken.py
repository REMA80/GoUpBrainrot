import sys, cv2, numpy as np, potrace
SRC = sys.argv[1]; OUT = sys.argv[2]
UP = 4
im = cv2.imread(SRC, cv2.IMREAD_GRAYSCALE)
im = cv2.resize(im, None, fx=UP, fy=UP, interpolation=cv2.INTER_CUBIC)
bw = (im < 110).astype(np.uint8)
ys, xs = np.nonzero(bw); x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
text_w_px = x1 - x0

def make(width_mm, min_stroke_mm, tag):
    mmpx = width_mm / text_w_px
    # aktuelle duennste Strichstaerke schaetzen (Median der Skelett-Halbbreiten)
    dist = cv2.distanceTransform(bw, cv2.DIST_L2, 5)
    sk = cv2.ximgproc.thinning(bw * 255) if hasattr(cv2, "ximgproc") else None
    thin_half = np.percentile(dist[dist > 0.5 * dist.max() * 0 + 1], 10)
    r = max(0, int(round(min_stroke_mm / 2 / mmpx - thin_half)))
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1, 2 * r + 1))
    g = cv2.dilate(bw, k)
    # Einzelteile mit Steg verbinden (naechste Punkte), bis alles ein Teil ist
    bridge_w = max(3, int(round(min_stroke_mm * 1.1 / mmpx)))
    while True:
        n, lab = cv2.connectedComponents(g, connectivity=8)
        if n <= 2: break
        sizes = [(lab == i).sum() for i in range(1, n)]
        main = 1 + int(np.argmax(sizes))
        others = [i for i in range(1, n) if i != main]
        mp = np.column_stack(np.nonzero(lab == main))[::7]
        best = None
        for o in others:
            op = np.column_stack(np.nonzero(lab == o))[::7]
            from scipy.spatial import cKDTree
            d, idx = cKDTree(mp).query(op)
            j = int(np.argmin(d))
            if best is None or d[j] < best[0]: best = (d[j], op[j], mp[idx[j]])
        _, a, b = best
        cv2.line(g, (int(a[1]), int(a[0])), (int(b[1]), int(b[0])), 1, bridge_w)
    g = cv2.GaussianBlur(g.astype(np.float32), (0, 0), UP * 0.8) > 0.5
    # winzige Loecher (< 4 mm2) fuellen, die wuerden nur als Kruemel herausfallen
    inv = (~g).astype(np.uint8)
    n2, lab2, st2, _ = cv2.connectedComponentsWithStats(inv, 4)
    for i in range(1, n2):
        x, y, w, h, a = st2[i]
        if x > 0 and y > 0 and x + w < g.shape[1] and y + h < g.shape[0] and a * mmpx * mmpx < 4.0:
            g[lab2 == i] = True
    g = np.pad(g, 10)
    bm = potrace.Bitmap(~g)
    plist = bm.trace(turdsize=50, alphamax=1.0, opticurve=True, opttolerance=0.2)
    ys, xs = np.nonzero(g); gx0, gy0, gx1, gy1 = xs.min(), ys.min(), xs.max(), ys.max()
    m = 5.0
    f = lambda p: ((p.x - gx0) * mmpx + m, (p.y - gy0) * mmpx + m)
    ds = []
    for curve in plist:
        st = f(curve.start_point); d = [f"M{st[0]:.3f},{st[1]:.3f}"]
        for seg in curve.segments:
            if seg.is_corner:
                c = f(seg.c); e = f(seg.end_point)
                d.append(f"L{c[0]:.3f},{c[1]:.3f} L{e[0]:.3f},{e[1]:.3f}")
            else:
                c1, c2, e = f(seg.c1), f(seg.c2), f(seg.end_point)
                d.append(f"C{c1[0]:.3f},{c1[1]:.3f} {c2[0]:.3f},{c2[1]:.3f} {e[0]:.3f},{e[1]:.3f}")
        ds.append(" ".join(d) + " Z")
    W = (gx1 - gx0) * mmpx + 2 * m; H = (gy1 - gy0) * mmpx + 2 * m
    base = f"{OUT}/willkommen_{tag}"
    svg = lambda prev: "\n".join([
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.1f}mm" height="{H:.1f}mm" viewBox="0 0 {W:.3f} {H:.3f}">',
        '  <!-- ROT = Schneiden. Schriftzug verdickt und zu einem Teil verbunden. -->',
        (f'  <rect width="{W}" height="{H}" fill="#ffffff"/>\n  <path fill="#c9a77c" fill-rule="evenodd" d="{" ".join(ds)}"/>' if prev else ""),
        f'  <g fill="none" stroke="#FF0000" stroke-width="{0.3 if prev else 0.1}">',
        *[f'    <path d="{d}"/>' for d in ds], "  </g>", "</svg>"])
    open(base + ".svg", "w").write(svg(False))
    open(f"{OUT}/../../../tmp_prev_{tag}.svg" if False else f"/tmp/claude-0/-home-user-GoUpBrainrot/9096847a-4aab-564d-aca4-6311e8b4f1c2/scratchpad/prev_{tag}.svg", "w").write(svg(True))
    # duennste Stelle im Ergebnis messen
    dd = cv2.distanceTransform(g.astype(np.uint8), cv2.DIST_L2, 5)
    skel_vals = dd[(dd > 0) & (cv2.dilate(dd, np.ones((3, 3))) == dd)]
    print(tag, f"{W:.0f} x {H:.0f} mm, Dilatation r={r}px, duennste Stelle ca. {2 * np.percentile(skel_vals, 2) * mmpx:.1f} mm, Teile: {len(plist)} Konturen")

make(300, 3.0, "300mm")
