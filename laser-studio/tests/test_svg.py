import itertools
import re
import unittest
import xml.etree.ElementTree as ET

from goose_laser.geometry.box import LID_TYPES
from goose_laser.service import InputError, calculate_box, export_box_svg

NS = {"svg": "http://www.w3.org/2000/svg"}

BASE = dict(length=150, width=100, height=60, thickness=3, kerf=0.1, lid="offen",
            joint="stumpf", sheet_width=400, sheet_height=300, margin=5, gap=3)


def parse_loops(d):
    """Liest einen Pfad aus Unterpfaden 'M x y L x y ... Z' (nur M/L/Z erlaubt)."""
    loops = []
    for sub in d.split("M ")[1:]:
        sub = sub.strip()
        assert sub.endswith("Z"), f"Unterpfad nicht geschlossen: {sub[:40]}"
        pts = [tuple(map(float, pt.split())) for pt in sub[:-1].split(" L ")]
        for a, b in zip(pts, pts[1:] + pts[:1]):
            assert a[0] == b[0] or a[1] == b[1], "Segment nicht achsparallel"
        loops.append(pts)
    return loops


def rect_from_path(d):
    """Begrenzungsrechteck (x0, y0, x1, y1) eines Pfads."""
    pts = [p for loop in parse_loops(d) for p in loop]
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


class SvgExportTest(unittest.TestCase):
    def test_svg_parses_and_has_mm_units(self):
        name, svg = export_box_svg(BASE)
        self.assertTrue(name.endswith(".svg"))
        root = ET.fromstring(svg.encode("utf-8"))
        self.assertEqual(root.tag, "{http://www.w3.org/2000/svg}svg")
        self.assertEqual(root.get("width"), "400mm")
        self.assertEqual(root.get("height"), "300mm")
        self.assertEqual(root.get("viewBox"), "0 0 400 300")

    def test_export_contains_only_closed_cut_paths(self):
        for lid in LID_TYPES:
            with self.subTest(lid=lid):
                _, svg = export_box_svg({**BASE, "lid": lid})
                root = ET.fromstring(svg.encode("utf-8"))
                self.assertEqual(root.findall(".//svg:text", NS), [], "kein Text in der Exportdatei")
                self.assertEqual(root.findall(".//svg:rect", NS), [], "kein Plattenrand in der Exportdatei")
                group = root.find("svg:g[@id='schnitt']", NS)
                self.assertEqual(group.get("stroke"), "#ff0000")
                self.assertEqual(group.get("fill"), "none")
                paths = root.findall(".//svg:path", NS)
                self.assertEqual(len(paths), 5 if lid == "offen" else 6)
                for p in paths:
                    self.assertTrue(p.get("d").endswith("Z"))

    def test_svg_rectangles_match_cut_sizes_and_do_not_overlap(self):
        for t, kerf in itertools.product([2, 3, 6], [0, 0.15]):
            with self.subTest(t=t, kerf=kerf):
                data = {**BASE, "thickness": t, "kerf": kerf, "lid": "aufgelegt"}
                result = calculate_box(data)
                _, svg = export_box_svg(data)
                root = ET.fromstring(svg.encode("utf-8"))
                rects = {}
                for p in root.findall(".//svg:path", NS):
                    x, y, x2, y2 = rect_from_path(p.get("d"))
                    rects[p.get("id").removeprefix("teil-")] = (x, y, x2, y2)
                for panel in result["panels"]:
                    x, y, x2, y2 = rects[panel["key"]]
                    self.assertAlmostEqual(x2 - x, panel["cut_width"], places=3)
                    self.assertAlmostEqual(y2 - y, panel["cut_height"], places=3)
                    self.assertGreaterEqual(x, 5 - 1e-9)
                    self.assertGreaterEqual(y, 5 - 1e-9)
                    self.assertLessEqual(x2, 395 + 1e-9)
                    self.assertLessEqual(y2, 295 + 1e-9)
                boxes = list(rects.values())
                for a, b in itertools.combinations(boxes, 2):
                    separated = a[2] < b[0] or b[2] < a[0] or a[3] < b[1] or b[3] < a[1]
                    self.assertTrue(separated, f"Überschneidung/Berührung: {a} {b}")

    def test_no_svg_for_invalid_design(self):
        with self.assertRaises(InputError):
            export_box_svg({**BASE, "length": 5})
        with self.assertRaises(InputError):
            export_box_svg({**BASE, "sheet_width": 100})  # Teile zu groß

    def test_preview_has_labels_but_export_not(self):
        result = calculate_box(BASE)
        root = ET.fromstring(result["preview_svg"].encode("utf-8"))
        texts = [t.text for t in root.findall(".//svg:text", NS)]
        self.assertIn("Vorderwand", texts)


if __name__ == "__main__":
    unittest.main()
