import json
import threading
import unittest
import urllib.error
import urllib.request

from goose_laser.server.app import make_server

BASE = dict(length=150, width=100, height=60, thickness=3, kerf=0.1, lid="eingesetzt",
            joint="stumpf", sheet_width=400, sheet_height=300, margin=5, gap=3)


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = make_server(0)  # freier Port
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def post(self, path, payload):
        req = urllib.request.Request(self.base + path, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req) as res:
                return res.status, dict(res.headers), res.read()
        except urllib.error.HTTPError as err:
            return err.code, dict(err.headers), err.read()

    def get(self, path):
        try:
            with urllib.request.urlopen(self.base + path) as res:
                return res.status, dict(res.headers), res.read()
        except urllib.error.HTTPError as err:
            return err.code, dict(err.headers), err.read()

    def test_index_and_static(self):
        status, headers, body = self.get("/")
        self.assertEqual(status, 200)
        self.assertIn("Goose Village Laser Studio", body.decode())
        status, headers, _ = self.get("/static/app.js")
        self.assertEqual(status, 200)
        self.assertIn("javascript", headers["Content-Type"])

    def test_path_traversal_blocked(self):
        status, _, _ = self.get("/static/../run.py")
        self.assertEqual(status, 404)
        status, _, _ = self.get("/static/%2e%2e/run.py")
        self.assertEqual(status, 404)

    def test_calculate_ok(self):
        status, _, body = self.post("/api/box/calculate", BASE)
        self.assertEqual(status, 200)
        data = json.loads(body)
        self.assertTrue(data["ok"])
        self.assertEqual(len(data["result"]["panels"]), 6)

    def test_calculate_invalid_returns_errors(self):
        status, _, body = self.post("/api/box/calculate", {**BASE, "thickness": 0})
        self.assertEqual(status, 422)
        data = json.loads(body)
        self.assertFalse(data["ok"])
        self.assertEqual(data["errors"][0]["field"], "thickness")

    def test_export_returns_svg_download(self):
        status, headers, body = self.post("/api/box/export", BASE)
        self.assertEqual(status, 200)
        self.assertTrue(headers["Content-Type"].startswith("image/svg+xml"))
        self.assertIn("attachment", headers["Content-Disposition"])
        self.assertTrue(body.startswith(b"<?xml"))

    def test_export_refused_for_invalid_design(self):
        status, _, body = self.post("/api/box/export", {**BASE, "height": 2})
        self.assertEqual(status, 422)
        self.assertNotIn(b"<svg", body)

    def test_bad_json(self):
        req = urllib.request.Request(self.base + "/api/box/calculate", data=b"{kaputt",
                                     headers={"Content-Type": "application/json"}, method="POST")
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req)
        self.assertEqual(ctx.exception.code, 400)


if __name__ == "__main__":
    unittest.main()
