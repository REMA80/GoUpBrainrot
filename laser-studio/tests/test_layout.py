import unittest

from goose_laser.layout.simple import (
    Item,
    LayoutError,
    PlacedItem,
    SheetParams,
    parse_sheet,
    shelf_layout,
    verify_layout,
)


class LayoutTest(unittest.TestCase):
    def test_no_overlap_and_inside_sheet(self):
        sheet = SheetParams(400, 300, 5, 3)
        items = [Item(f"t{i}", f"Teil {i}", 40 + i * 7.3, 20 + (i % 4) * 11) for i in range(12)]
        placed = shelf_layout(items, sheet)
        self.assertEqual(len(placed), 12)
        self.assertEqual(verify_layout(placed, sheet), [])

    def test_gap_respected(self):
        sheet = SheetParams(400, 300, 5, 3)
        placed = shelf_layout([Item("a", "A", 100, 50), Item("b", "B", 100, 50)], sheet)
        a, b = sorted(placed, key=lambda p: p.x)
        self.assertAlmostEqual(b.x - (a.x + a.width), 3)

    def test_verify_detects_overlap_and_outside(self):
        sheet = SheetParams(100, 100, 5, 2)
        placed = [PlacedItem("a", "A", 5, 5, 50, 50), PlacedItem("b", "B", 54, 5, 30, 30)]
        self.assertTrue(any("überschneiden" in m for m in verify_layout(placed, sheet)))
        placed = [PlacedItem("a", "A", 60, 5, 50, 50)]
        self.assertTrue(any("außerhalb" in m for m in verify_layout(placed, sheet)))

    def test_part_too_large(self):
        with self.assertRaises(LayoutError):
            shelf_layout([Item("a", "A", 395, 10)], SheetParams(400, 300, 5, 3))

    def test_does_not_fit_on_one_sheet(self):
        items = [Item(f"t{i}", f"T{i}", 180, 140) for i in range(6)]
        with self.assertRaises(LayoutError):
            shelf_layout(items, SheetParams(400, 300, 5, 3))

    def test_sheet_validation(self):
        for data in (
            dict(sheet_width=400, sheet_height=300, margin=5, gap=0),
            dict(sheet_width=0, sheet_height=300, margin=5, gap=3),
            dict(sheet_width=400, sheet_height=300, margin=-1, gap=3),
            dict(sheet_width=400, sheet_height=300, margin=200, gap=3),
            dict(sheet_width="x", sheet_height=300, margin=5, gap=3),
        ):
            with self.subTest(data=data):
                with self.assertRaises(LayoutError):
                    parse_sheet(data)


if __name__ == "__main__":
    unittest.main()
