import itertools
import unittest

from goose_laser.geometry.box import (
    LID_TYPES,
    BoxParams,
    ValidationError,
    build_box,
    parse_params,
    verify_assembly,
)
from goose_laser.geometry.outline import bbox, signed_area


def inside(loops, u, v):
    """Punkt-in-Polygon (gerade/ungerade-Regel) über alle Konturen eines Teils."""
    hit = False
    for loop in loops:
        n = len(loop)
        for k in range(n):
            (x0, y0), (x1, y1) = loop[k - 1], loop[k]
            if (y0 > v) != (y1 > v):
                x = x0 + (v - y0) * (x1 - x0) / (y1 - y0)
                if x > u:
                    hit = not hit
    return hit


def panel(design, key):
    return next(p for p in design.panels if p.key == key)


def finger(L=150, B=100, H=60, t=3, kerf=0.0, lid="offen", fw=9, c=0.0):
    return build_box(BoxParams(L, B, H, t, kerf, lid, "fingerzinken", fw, c))


def samples(a, b, count=400):
    return [a + (b - a) * (k + 0.5) / count for k in range(count)]


class FingerJointTest(unittest.TestCase):
    def test_many_combinations_assemble_exactly(self):
        sizes = [(150, 100, 60), (300, 200, 120), (60.5, 47.3, 38.9), (500, 80, 250)]
        for (L, B, H), t, kerf, lid, c, fw in itertools.product(
            sizes, [2, 3, 6], [0, 0.2], LID_TYPES, [0, 0.3], [6, 15]
        ):
            with self.subTest(L=L, B=B, H=H, t=t, kerf=kerf, lid=lid, c=c, fw=fw):
                try:
                    d = finger(L, B, H, t, kerf, lid, fw, c)
                except ValidationError as exc:
                    # Nur erlaubte Ablehnung: Kante zu kurz für diese Zinkenbreite
                    self.assertTrue(all("zu kurz" in e["message"] for e in exc.errors), exc.errors)
                    continue
                self.assertEqual(verify_assembly(d), [])
                for e in d.edges:
                    self.assertEqual(e.segments % 2, 1)
                    self.assertGreaterEqual(e.segments, 3)
                for p in d.panels:
                    self.assertEqual(len(p.loops), 1, f"{p.name} hat Löcher oder zerfällt")
                    self.assertGreater(signed_area(p.loops[0]), 0)

    def _check_edge(self, d, key_a, key_b, a_u, b_u, v_range):
        """Entlang einer Kante muss an jedem Messpunkt genau ein Teil Material haben
        (bei Spiel 0) bzw. höchstens eines (bei Spiel > 0)."""
        pa, pb = panel(d, key_a), panel(d, key_b)
        c = d.params.clearance
        owners = []
        for v in samples(*v_range):
            ia = inside(pa.loops, a_u, v)
            ib = inside(pb.loops, b_u, v)
            self.assertFalse(ia and ib, f"Überschneidung bei {v:.3f}")
            if c == 0:
                self.assertTrue(ia or ib, f"Lücke bei {v:.3f}")
            owners.append("a" if ia else "b" if ib else "-")
        return owners

    def test_2d_outlines_interlock_without_gap_or_overlap(self):
        for lid in LID_TYPES:
            with self.subTest(lid=lid):
                d = finger(lid=lid)
                t, L, B = 3, 150, 100
                # Senkrechte Ecke: Vorderwand (u=x nahe 0) gegen linke Seitenwand (u=y nahe 0)
                owners = self._check_edge(d, "front", "left", t / 2, t / 2, (0, d.wall_height))
                self.assertIn("a", owners)
                self.assertIn("b", owners)
                # Bodenkante vorne: Vorderwand (v=z nahe 0) gegen Boden (v=y nahe 0).
                # Hier verläuft die Kante entlang u; wir tasten daher u ab.
                front, bottom = panel(d, "front"), panel(d, "bottom")
                seen = set()
                for u in samples(0, L):
                    a = inside(front.loops, u, t / 2)
                    b = inside(bottom.loops, u, t / 2)
                    self.assertNotEqual(a, b, f"Bodenkante vorne bei x={u:.3f}")
                    seen.add(a)
                self.assertEqual(seen, {True, False})
                # Bodenkante links: Seitenwand (u=y) gegen Boden (u=x nahe 0, v=y)
                left = panel(d, "left")
                for y in samples(t, B - t):
                    a = inside(left.loops, y, t / 2)
                    b = inside(bottom.loops, t / 2, y)
                    self.assertNotEqual(a, b, f"Bodenkante links bei y={y:.3f}")

    def test_clearance_leaves_gaps_but_no_overlap(self):
        d = finger(c=0.4)
        owners = self._check_edge(d, "front", "left", 1.5, 1.5, (0, 60))
        self.assertIn("-", owners)
        self.assertEqual(verify_assembly(d), [])
        self.assertGreater(d.expected_gap_volume, 0)

    def test_segment_widths(self):
        d = finger(L=150, B=100, H=60, t=3, fw=9)
        widths = {e.name: (e.segments, round(e.segment_width, 6)) for e in d.edges}
        self.assertEqual(widths["Boden – Vorder-/Rückwand"], (15, 9.6))  # 144 / 15
        self.assertEqual(widths["Boden – Seitenwände"], (9, round(94 / 9, 6)))
        self.assertEqual(widths["Senkrechte Ecken"], (5, 11.4))  # 57 / 5

    def test_kerf_widens_fingers_and_narrows_slots(self):
        k = 0.2
        d = finger(kerf=k)
        bottom = panel(d, "bottom")
        # Erste Zinke des Bodens an der Vorderkante: Nennbereich x in [12.6, 22.2]
        xs_nom = sorted({round(p[0], 6) for p in bottom.loops[0] if abs(p[1] - 0) < 1e-9})
        xs_cut = sorted({round(p[0], 6) for p in bottom.cut_loops[0] if abs(p[1] + k / 2) < 1e-9})
        self.assertEqual(xs_nom[:2], [12.6, 22.2])
        self.assertAlmostEqual(xs_cut[1] - xs_cut[0], 9.6 + k)  # Zinke breiter
        self.assertAlmostEqual(xs_cut[2] - xs_cut[1], 9.6 - k)  # Schlitz schmaler
        u0, v0, u1, v1 = bbox(bottom.cut_loops)
        self.assertAlmostEqual(u1 - u0, 150 + k)
        self.assertAlmostEqual(v1 - v0, 100 + k)

    def test_nominal_panel_sizes(self):
        d = finger(lid="eingesetzt")
        sizes = {p.key: (round(p.width, 6), round(p.height, 6)) for p in d.panels}
        self.assertEqual(sizes, {
            "front": (150, 60), "back": (150, 60), "left": (100, 60), "right": (100, 60),
            "bottom": (150, 100), "lid": (150, 100),
        })
        d = finger(lid="aufgelegt")
        sizes = {p.key: (round(p.width, 6), round(p.height, 6)) for p in d.panels}
        self.assertEqual(sizes["front"], (150, 57))
        self.assertEqual(sizes["lid"], (150, 100))

    def test_rejections(self):
        base = dict(length=150, width=100, height=60, thickness=3, joint="fingerzinken",
                    finger_width=9, clearance=0, kerf=0.1)
        cases = [
            ({"finger_width": 40}, "finger_width"),  # Kante zu kurz für 3 Abschnitte
            ({"finger_width": 0.5}, "finger_width"),
            ({"clearance": -0.1}, "clearance"),
            ({"clearance": 2}, "clearance"),
            ({"finger_width": "x"}, "finger_width"),
            ({"length": 2000, "finger_width": 1}, "finger_width"),  # zu viele Zinken
        ]
        for change, field in cases:
            with self.subTest(change=change):
                with self.assertRaises(ValidationError) as ctx:
                    build_box(parse_params({**base, **change}))
                self.assertIn(field, [e["field"] for e in ctx.exception.errors])

    def test_kerf_too_wide_for_slots_rejected(self):
        with self.assertRaises(ValidationError) as ctx:
            finger(t=3, fw=1.2, kerf=1.5)
        self.assertEqual(ctx.exception.errors[0]["field"], "kerf")

    def test_verify_detects_overlap(self):
        d = finger()
        left = panel(d, "left")
        left.boxes.append(panel(d, "front").boxes[3])
        self.assertTrue(any("überschneiden" in m for m in verify_assembly(d)))

    def test_butt_joint_unchanged(self):
        d = build_box(BoxParams(150, 100, 60, 3, 0, "offen", "stumpf"))
        self.assertEqual(d.edges, [])
        self.assertEqual(len(panel(d, "left").loops[0]), 4)


if __name__ == "__main__":
    unittest.main()
