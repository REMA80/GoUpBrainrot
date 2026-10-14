"""Umrisse aus achsparallelen Rechtecken (z. B. Fingerzinken) berechnen.

Ablauf:
1. ``union_loops``: Vereinigung von Rechtecken -> geschlossene Umrisslinien.
   Gearbeitet wird auf einem Raster aus allen vorkommenden Koordinaten,
   daher ist das Ergebnis exakt (keine Näherung).
   Mathematische Orientierung (y nach oben): Außenkontur gegen den
   Uhrzeigersinn, Löcher im Uhrzeigersinn; Material liegt immer links
   der Laufrichtung.
2. ``offset_loop``: Kontur um einen Abstand nach außen (vom Material weg)
   versetzen – für den Kerf-Ausgleich.
3. ``find_self_intersections``: prüft, ob sich Konturen schneiden oder
   berühren (z. B. wenn ein Schlitz schmaler als die Schnittfuge ist).
"""

from __future__ import annotations

Point = tuple[float, float]
Rect = tuple[float, float, float, float]  # x0, y0, x1, y1

EPS = 1e-9
_ND = 9  # Rundungsstellen für Koordinatenschlüssel


def _key(v: float) -> float:
    return round(v, _ND) + 0.0


def union_loops(rects: list[Rect]) -> list[list[Point]]:
    rects = [r for r in rects if r[2] - r[0] > EPS and r[3] - r[1] > EPS]
    if not rects:
        return []
    xs = sorted({_key(v) for r in rects for v in (r[0], r[2])})
    ys = sorted({_key(v) for r in rects for v in (r[1], r[3])})
    xi = {x: i for i, x in enumerate(xs)}
    yi = {y: j for j, y in enumerate(ys)}

    filled: set[tuple[int, int]] = set()
    for x0, y0, x1, y1 in rects:
        for i in range(xi[_key(x0)], xi[_key(x1)]):
            for j in range(yi[_key(y0)], yi[_key(y1)]):
                filled.add((i, j))

    # Gerichtete Randkanten, Material links der Laufrichtung.
    outgoing: dict[tuple[int, int], list[tuple[int, int]]] = {}

    def add(a, b):
        outgoing.setdefault(a, []).append(b)

    for i, j in filled:
        if (i, j - 1) not in filled:
            add((i, j), (i + 1, j))
        if (i + 1, j) not in filled:
            add((i + 1, j), (i + 1, j + 1))
        if (i, j + 1) not in filled:
            add((i + 1, j + 1), (i, j + 1))
        if (i - 1, j) not in filled:
            add((i, j + 1), (i, j))

    loops: list[list[Point]] = []
    for start in sorted(outgoing):
        while outgoing.get(start):
            loop = [start]
            nxt = outgoing[start].pop(0)
            prev = start
            cur = nxt
            while cur != start:
                loop.append(cur)
                d = (cur[0] - prev[0], cur[1] - prev[1])
                candidates = outgoing.get(cur, [])
                # Bevorzugt links abbiegen -> sich an einem Punkt
                # berührende Flächen werden als getrennte Konturen erkannt.
                prefs = [(-d[1], d[0]), d, (d[1], -d[0])]
                chosen = None
                for pd in prefs:
                    for c in candidates:
                        if (c[0] - cur[0], c[1] - cur[1]) == pd:
                            chosen = c
                            break
                    if chosen:
                        break
                if chosen is None:
                    raise RuntimeError("Umriss nicht geschlossen")
                candidates.remove(chosen)
                prev, cur = cur, chosen
            pts = [(xs[i], ys[j]) for i, j in loop]
            loops.append(simplify(pts))
    return loops


def simplify(pts: list[Point]) -> list[Point]:
    """Entfernt Punkte, die auf einer Geraden zwischen ihren Nachbarn liegen."""
    out = list(pts)
    changed = True
    while changed and len(out) > 3:
        changed = False
        for k in range(len(out)):
            a, b, c = out[k - 1], out[k], out[(k + 1) % len(out)]
            cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
            if abs(cross) < EPS:
                del out[k]
                changed = True
                break
    return out


def signed_area(pts: list[Point]) -> float:
    s = 0.0
    for k in range(len(pts)):
        x0, y0 = pts[k - 1]
        x1, y1 = pts[k]
        s += x0 * y1 - x1 * y0
    return s / 2


def offset_loop(pts: list[Point], dist: float) -> list[Point]:
    """Versetzt eine rechtwinklige Kontur um ``dist`` vom Material weg."""
    if dist == 0:
        return list(pts)
    n = len(pts)
    out = []
    for k in range(n):
        a, b, c = pts[k - 1], pts[k], pts[(k + 1) % n]
        n_in = _right_normal(a, b)
        n_out = _right_normal(b, c)
        out.append((b[0] + dist * (n_in[0] + n_out[0]), b[1] + dist * (n_in[1] + n_out[1])))
    return out


def _right_normal(a: Point, b: Point) -> Point:
    dx, dy = b[0] - a[0], b[1] - a[1]
    length = (dx * dx + dy * dy) ** 0.5
    if abs(dx) > EPS and abs(dy) > EPS:
        raise ValueError("Nur rechtwinklige Konturen werden unterstützt")
    return (dy / length, -dx / length)


def _segments(loops: list[list[Point]]):
    for li, loop in enumerate(loops):
        n = len(loop)
        for k in range(n):
            yield li, k, n, loop[k], loop[(k + 1) % n]


def _seg_touch(p1: Point, p2: Point, q1: Point, q2: Point, tol: float = 1e-7) -> bool:
    ax0, ax1 = sorted((p1[0], p2[0]))
    ay0, ay1 = sorted((p1[1], p2[1]))
    bx0, bx1 = sorted((q1[0], q2[0]))
    by0, by1 = sorted((q1[1], q2[1]))
    return ax0 <= bx1 + tol and bx0 <= ax1 + tol and ay0 <= by1 + tol and by0 <= ay1 + tol


def find_self_intersections(loops: list[list[Point]]) -> int:
    """Anzahl sich schneidender/berührender Segmentpaare (benachbarte ausgenommen).

    Gilt für rechtwinklige Konturen, bei denen sich achsparallele Segmente
    nur dann schneiden, wenn sich ihre Begrenzungsrechtecke überlappen.
    """
    tol = 1e-7
    # Sweep entlang x: nur Segmente vergleichen, deren x-Bereiche sich überlappen.
    segs = sorted(_segments(loops), key=lambda s: min(s[3][0], s[4][0]))
    count = 0
    for a in range(len(segs)):
        la, ka, na, p1, p2 = segs[a]
        a_x1 = max(p1[0], p2[0])
        for b in range(a + 1, len(segs)):
            lb, kb, nb, q1, q2 = segs[b]
            if min(q1[0], q2[0]) > a_x1 + tol:
                break
            if la == lb and (abs(ka - kb) == 1 or abs(ka - kb) == na - 1):
                continue  # benachbarte Segmente teilen einen Eckpunkt
            if _seg_touch(p1, p2, q1, q2, tol):
                count += 1
    return count


def bbox(loops: list[list[Point]]) -> Rect:
    xs = [p[0] for loop in loops for p in loop]
    ys = [p[1] for loop in loops for p in loop]
    return (min(xs), min(ys), max(xs), max(ys))
