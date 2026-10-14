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


class BoxGeometryTest(unittest.TestCase):
    SIZES = [(150, 100, 60), (300, 200, 120), (40.5, 33.3, 25.7), (600, 80, 400)]
    THICKNESSES = [1.5, 3, 4, 6]
    KERFS = [0, 0.08, 0.15, 0.3]

    def test_all_combinations_assemble_exactly(self):
        for (L, B, H), t, kerf, lid in itertools.product(self.SIZES, self.THICKNESSES, self.KERFS, LID_TYPES):
            with self.subTest(L=L, B=B, H=H, t=t, kerf=kerf, lid=lid):
                design = build_box(BoxParams(L, B, H, t, kerf, lid))
                self.assertEqual(verify_assembly(design), [])

    def test_inner_dimensions(self):
        L, B, H, t = 150, 100, 60, 3
        expected_h = {"offen": H - t, "eingesetzt": H - 2 * t, "aufgelegt": H - 2 * t}
        for lid in LID_TYPES:
            with self.subTest(lid=lid):
                d = build_box(BoxParams(L, B, H, t, 0, lid))
                self.assertAlmostEqual(d.inner_length, 144)
                self.assertAlmostEqual(d.inner_width, 94)
                self.assertAlmostEqual(d.inner_height, expected_h[lid])

    def test_panel_counts_and_sizes(self):
        d = build_box(BoxParams(150, 100, 60, 3, 0, "offen"))
        sizes = {p.key: (p.width, p.height) for p in d.panels}
        self.assertEqual(sizes, {
            "front": (150, 60), "back": (150, 60),
            "left": (94, 60), "right": (94, 60),
            "bottom": (144, 94),
        })
        d = build_box(BoxParams(150, 100, 60, 3, 0, "aufgelegt"))
        sizes = {p.key: (p.width, p.height) for p in d.panels}
        self.assertEqual(sizes["front"], (150, 57))
        self.assertEqual(sizes["lid"], (150, 100))
        d = build_box(BoxParams(150, 100, 60, 3, 0, "eingesetzt"))
        self.assertEqual({p.key: (p.width, p.height) for p in d.panels}["lid"], (144, 94))

    def test_outer_bounding_box_matches_input(self):
        for lid in LID_TYPES:
            d = build_box(BoxParams(210, 130, 75, 4, 0.1, lid))
            boxes = [b for p in d.panels for b in p.boxes]
            self.assertAlmostEqual(min(b.x0 for b in boxes), 0)
            self.assertAlmostEqual(max(b.x1 for b in boxes), 210)
            self.assertAlmostEqual(max(b.y1 for b in boxes), 130)
            self.assertAlmostEqual(max(b.z1 for b in boxes), 75)

    def test_kerf_enlarges_cut_line(self):
        d = build_box(BoxParams(150, 100, 60, 3, 0.2, "offen"))
        front = next(p for p in d.panels if p.key == "front")
        self.assertEqual(front.cut_size(0.2), (150.2, 60.2))

    def test_verify_detects_broken_design(self):
        d = build_box(BoxParams(150, 100, 60, 3, 0, "offen"))
        d.panels.pop()  # Boden entfernen
        self.assertTrue(any("lückenlos" in m for m in verify_assembly(d)))

    def test_impossible_inputs_rejected(self):
        bad = [
            dict(length=6, width=100, height=60, thickness=3),  # L = 2t
            dict(length=150, width=5, height=60, thickness=3),  # B < 2t
            dict(length=150, width=100, height=3, thickness=3, lid="offen"),  # H = t
            dict(length=150, width=100, height=6, thickness=3, lid="eingesetzt"),  # H = 2t
            dict(length=150, width=100, height=60, thickness=0),
            dict(length=-1, width=100, height=60, thickness=3),
            dict(length=150, width=100, height=60, thickness=3, kerf=-0.1),
            dict(length=150, width=100, height=60, thickness=1, kerf=1),  # kerf >= t
            dict(length="abc", width=100, height=60, thickness=3),
            dict(length=float("nan"), width=100, height=60, thickness=3),
            dict(length=True, width=100, height=60, thickness=3),
            dict(length=150, width=100, height=60, thickness=3, lid="schiebedeckel"),
            dict(length=150, width=100, height=60, thickness=3, joint="schwalbenschwanz"),
            dict(width=100, height=60, thickness=3),
        ]
        for data in bad:
            with self.subTest(data=data):
                with self.assertRaises(ValidationError) as ctx:
                    parse_params(data)
                self.assertTrue(ctx.exception.errors)

    def test_string_numbers_accepted(self):
        p = parse_params({"length": "150", "width": "100.5", "height": "60", "thickness": "3", "kerf": "0.1"})
        self.assertEqual((p.length, p.width, p.kerf), (150.0, 100.5, 0.1))


if __name__ == "__main__":
    unittest.main()
