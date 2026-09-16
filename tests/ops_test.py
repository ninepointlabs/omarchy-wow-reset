"""Offline tests for bin/wow-reset-ops: parsers against saved API responses,
and the settings store (symlinks, FIFOs, modes, credentials never echoed).

Run: /usr/bin/python3 -I -B tests/ops_test.py
"""
import importlib.machinery
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OPS = os.path.join(ROOT, "bin", "wow-reset-ops")
FIXTURES = os.path.join(ROOT, "tests", "fixtures")

loader = importlib.machinery.SourceFileLoader("wow_reset_ops", OPS)
spec = importlib.util.spec_from_loader("wow_reset_ops", loader)
ops = importlib.util.module_from_spec(spec)
loader.exec_module(ops)

# Thu 2026-09-17 12:00 UTC; the Raider.io raid fixture was saved that week.
NOW_MS = 1789646400000


def fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as fh:
        return json.load(fh)


def run(home, request):
    proc = subprocess.run(
        ["/usr/bin/python3", "-I", "-S", "-B", OPS, "--home", home],
        input=json.dumps(request).encode(), capture_output=True, timeout=30,
        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8"},
    )
    return proc.returncode, json.loads(proc.stdout.decode())


class Parsers(unittest.TestCase):
    def test_affixes(self):
        parsed = ops.parse_affixes(fixture("affixes-us.json"), "us")
        self.assertEqual(parsed["region"], "us")
        names = [a["name"] for a in parsed["items"]]
        self.assertIn("Tyrannical", names)
        self.assertIn("Fortified", names)
        self.assertTrue(all(a["description"] for a in parsed["items"]))

    def test_current_raids_uses_region_window(self):
        raids = ops.parse_current_raids(fixture("raids-static.json"), "us", NOW_MS)
        self.assertEqual(sorted(r["name"] for r in raids), ["The Tidebound Grotto", "The Venomous Abyss"])
        abyss = [r for r in raids if r["slug"] == "the-venomous-abyss"][0]
        self.assertEqual(abyss["bosses"], 8)
        # Before the season started nothing from it is current.
        self.assertNotIn("the-venomous-abyss",
                         [r["slug"] for r in ops.parse_current_raids(fixture("raids-static.json"), "us", 1780000000000)])

    def test_character(self):
        raids = ops.parse_current_raids(fixture("raids-static.json"), "us", NOW_MS)
        c = ops.parse_rio_character(fixture("character-rio.json"), "us", raids)
        self.assertEqual((c["name"], c["realm"], c["className"]), ("Examplemonk", "Area 52", "Monk"))
        self.assertGreater(c["score"], 0)
        self.assertEqual(len(c["weeklyRuns"]), 3)
        self.assertTrue(all(r["level"] > 0 for r in c["weeklyRuns"]))
        self.assertEqual({p["name"] for p in c["progression"]}, {"The Tidebound Grotto", "The Venomous Abyss"})

    def test_encounters_keeps_only_current_raids(self):
        raids = [{"name": "The Venomous Abyss", "slug": "x", "bosses": 8},
                 {"name": "The Tidebound Grotto", "slug": "y", "bosses": 1}]
        instances = ops.parse_encounters(fixture("blizzard-encounters.json"), raids)
        self.assertEqual([i["name"] for i in instances], ["The Venomous Abyss", "The Tidebound Grotto"])
        heroic = instances[0]["modes"][0]
        self.assertEqual((heroic["difficulty"], heroic["total"]), ("HEROIC", 8))
        self.assertEqual(heroic["bosses"][0], {"name": "Boss One", "lastKill": 1789500000000})
        self.assertEqual(instances[0]["modes"][1]["bosses"][1]["name"], "Boss Four")

    def test_names(self):
        self.assertEqual(ops.valid_name("Examplemonk"), "Examplemonk")
        self.assertEqual(ops.valid_name("Ñoño"), "Ñoño")
        for bad in ("", "a", "bad1", "two words", "x/../y", "<b>"):
            self.assertEqual(ops.valid_name(bad), "", bad)
        self.assertEqual(ops.valid_realm("Kel'Thuzad"), "Kel'Thuzad")
        self.assertEqual(ops.valid_realm("Area 52"), "Area 52")
        self.assertEqual(ops.valid_realm("../etc"), "")
        self.assertEqual(ops.realm_slug("Kel'Thuzad"), "kelthuzad")
        self.assertEqual(ops.realm_slug("Area 52"), "area-52")
        self.assertEqual(ops.realm_slug("Azjol-Nerub"), "azjol-nerub")

    def test_iso_ms(self):
        self.assertEqual(ops.iso_ms("2026-09-15T15:00:00Z"), 1789484400000)
        self.assertEqual(ops.iso_ms("2026-09-15T15:00:00.000Z"), 1789484400000)
        self.assertEqual(ops.iso_ms("garbage"), 0)

    def test_refuses_other_hosts(self):
        with self.assertRaises(ops.RemoteError):
            ops.request_json("https://example.com/x", "Test")
        with self.assertRaises(ops.RemoteError):
            ops.request_json("http://raider.io/x", "Test")


def rgba_png(width, height, pixel):
    """A synthetic RGBA PNG through the helper's own encoder path, with
    every PNG filter type exercised by varying rows."""
    import struct as st
    import zlib as zl
    raw = bytearray()
    prev = bytearray(width * 4)
    for y in range(height):
        line = bytearray()
        for x in range(width):
            line += bytes(pixel(x, y))
        kind = y % 5
        raw.append(kind)
        for i in range(len(line)):
            left = line[i - 4] if i >= 4 else 0
            up = prev[i]
            corner = prev[i - 4] if i >= 4 else 0
            if kind == 0:
                raw.append(line[i])
            elif kind == 1:
                raw.append((line[i] - left) & 255)
            elif kind == 2:
                raw.append((line[i] - up) & 255)
            elif kind == 3:
                raw.append((line[i] - (left + up) // 2) & 255)
            else:
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                pred = left if pa <= pb and pa <= pc else up if pb <= pc else corner
                raw.append((line[i] - pred) & 255)
        prev = line

    def chunk(kind, body):
        return st.pack(">I", len(body)) + kind + body + st.pack(">I", zl.crc32(kind + body) & 0xFFFFFFFF)

    return (ops.PNG_SIGNATURE + chunk(b"IHDR", st.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zl.compress(bytes(raw))) + chunk(b"IEND", b""))


class Emblem(unittest.TestCase):
    def test_decode_all_filters(self):
        pixel = lambda x, y: ((x * 37) & 255, (y * 91) & 255, (x * y) & 255, (x + y * 7) & 255)
        width, height, px = ops.decode_png_rgba(rgba_png(13, 11, pixel))
        self.assertEqual((width, height), (13, 11))
        for y in range(height):
            for x in range(width):
                self.assertEqual(tuple(px[(y * width + x) * 4:(y * width + x) * 4 + 4]), pixel(x, y))

    def test_horde_uses_alpha_and_crops(self):
        # Opaque red square in the middle of a transparent 20x20.
        pixel = lambda x, y: (200, 0, 0, 255) if 5 <= x < 15 and 6 <= y < 12 else (0, 0, 0, 0)
        w, h, px = ops.decode_png_rgba(rgba_png(20, 20, pixel))
        cw, ch, mask = ops.crop_mask(w, h, ops.emblem_mask(w, h, px, "horde"))
        self.assertEqual((cw, ch), (12, 8))
        self.assertEqual(max(mask), 255)

    def test_alliance_keeps_gold_not_blue(self):
        gold, blue = (250, 200, 20, 255), (20, 40, 180, 255)
        pixel = lambda x, y: gold if x < 4 else blue
        w, h, px = ops.decode_png_rgba(rgba_png(8, 4, pixel))
        mask = ops.emblem_mask(w, h, px, "alliance")
        self.assertEqual(mask[0], 255)
        self.assertEqual(mask[7], 0)

    def test_encoded_mask_is_white_and_decodable(self):
        mask = bytearray(range(0, 250, 10))
        png = ops.encode_mask_png(5, 5, mask)
        w, h, px = ops.decode_png_rgba(png)
        self.assertEqual((w, h), (5, 5))
        self.assertEqual(bytes(px[0:3]), b"\xff\xff\xff")
        self.assertEqual([px[i * 4 + 3] for i in range(25)], list(mask))

    def test_refuses_bad_images(self):
        good = rgba_png(4, 4, lambda x, y: (1, 2, 3, 4))
        with self.assertRaises(ValueError):
            ops.decode_png_rgba(b"GIF89a" + good[6:])
        with self.assertRaises(ValueError):
            ops.decode_png_rgba(good[:40])
        corrupt = bytearray(good)
        corrupt[20] ^= 0xFF
        with self.assertRaises(ValueError):
            ops.decode_png_rgba(bytes(corrupt))
        with self.assertRaises(ValueError):
            ops.crop_mask(2, 2, bytearray(4))

    def test_refuses_oversized_and_bombs(self):
        import struct as st
        import zlib as zl

        def png(width, height, color_type, payload):
            def chunk(kind, body):
                return st.pack(">I", len(body)) + kind + body + st.pack(">I", zl.crc32(kind + body) & 0xFFFFFFFF)
            return (ops.PNG_SIGNATURE + chunk(b"IHDR", st.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0))
                    + chunk(b"IDAT", zl.compress(payload)) + chunk(b"IEND", b""))

        with self.assertRaises(ValueError):
            ops.decode_png_rgba(png(4096, 4096, 6, b"\0"))
        with self.assertRaises(ValueError):
            ops.decode_png_rgba(png(4, 4, 2, b"\0" * 52))
        # Declares 8x8 but inflates to 50 MB: stopped at the declared size.
        with self.assertRaises(ValueError):
            ops.decode_png_rgba(png(8, 8, 6, b"\0" * 50_000_000))

    def test_cached_emblem_is_served_without_network(self):
        with tempfile.TemporaryDirectory() as home:
            os.chmod(home, 0o755)
            state = os.path.join(home, ".local", "state", "omarchy-wow-reset")
            os.makedirs(state, mode=0o700)
            path = os.path.join(state, "emblem-horde.png")
            fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
            os.write(fd, ops.encode_mask_png(1, 1, bytearray([255])))
            os.close(fd)
            code, out = run(home, {"op": "emblem", "faction": "horde"})
            self.assertEqual(code, 0)
            self.assertEqual(out["emblem"], {"faction": "horde", "path": path})
            code, out = run(home, {"op": "emblem", "faction": "../../etc/passwd"})
            self.assertNotEqual(code, 0)
            self.assertEqual(out["error"], "Unknown faction")

    def test_symlinked_emblem_refused(self):
        with tempfile.TemporaryDirectory() as home:
            os.chmod(home, 0o755)
            state = os.path.join(home, ".local", "state", "omarchy-wow-reset")
            os.makedirs(state, mode=0o700)
            os.symlink("/etc/hostname", os.path.join(state, "emblem-alliance.png"))
            code, out = run(home, {"op": "emblem", "faction": "alliance"})
            self.assertNotEqual(code, 0)
            self.assertIn("symlink", out["error"])


class Store(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name
        os.chmod(self.home, 0o755)
        self.state = os.path.join(self.home, ".local", "state", "omarchy-wow-reset")

    def tearDown(self):
        self.tmp.cleanup()

    def test_save_and_load_sanitizes(self):
        code, out = run(self.home, {"op": "save", "config": {"characters": [
            {"region": "us", "name": "Examplemonk", "realm": "Area 52"},
            {"region": "US", "name": "examplemonk", "realm": "area-52"},
            {"region": "xx", "name": "Bad", "realm": "Realm"},
            {"region": "eu", "name": "Bad1", "realm": "Realm"},
        ]}})
        self.assertEqual((code, out), (0, {"ok": True}))
        info = os.stat(os.path.join(self.state, "config.json"))
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.state).st_mode), 0o700)
        code, out = run(self.home, {"op": "load"})
        self.assertEqual(code, 0)
        self.assertEqual(out["config"]["characters"], [{"region": "us", "name": "Examplemonk", "realm": "Area 52"}])
        self.assertFalse(out["blizzard"])

    def test_load_empty(self):
        code, out = run(self.home, {"op": "load"})
        self.assertEqual((code, out["config"]["characters"], out["blizzard"]), (0, [], False))

    def test_symlinked_config_refused(self):
        os.makedirs(self.state, mode=0o700)
        target = os.path.join(self.home, "elsewhere.json")
        with open(target, "w") as fh:
            fh.write('{"characters":[]}')
        os.symlink(target, os.path.join(self.state, "config.json"))
        code, out = run(self.home, {"op": "load"})
        self.assertNotEqual(code, 0)
        self.assertIn("symlink", out["error"])
        code, out = run(self.home, {"op": "save", "config": {"characters": []}})
        self.assertNotEqual(code, 0)

    def test_symlinked_state_directory_refused(self):
        os.makedirs(os.path.join(self.home, ".local", "state"), mode=0o700)
        os.makedirs(os.path.join(self.home, "real"), mode=0o700)
        os.symlink(os.path.join(self.home, "real"), self.state)
        code, out = run(self.home, {"op": "load"})
        self.assertNotEqual(code, 0)
        self.assertIn("symlink", out["error"])

    def test_fifo_does_not_hang(self):
        os.makedirs(self.state, mode=0o700)
        os.mkfifo(os.path.join(self.state, "config.json"), 0o600)
        code, out = run(self.home, {"op": "load"})
        self.assertNotEqual(code, 0)
        self.assertIn("not a regular file", out["error"])

    def test_world_writable_state_refused(self):
        os.makedirs(self.state, mode=0o700)
        os.chmod(self.state, 0o777)
        code, out = run(self.home, {"op": "load"})
        self.assertNotEqual(code, 0)
        self.assertIn("writable by other users", out["error"])

    def test_loose_file_mode_is_tightened(self):
        os.makedirs(self.state, mode=0o700)
        path = os.path.join(self.state, "config.json")
        with open(path, "w") as fh:
            fh.write('{"characters":[]}')
        os.chmod(path, 0o644)
        code, _out = run(self.home, {"op": "load"})
        self.assertEqual(code, 0)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_credentials_reported_but_never_returned(self):
        os.makedirs(self.state, mode=0o700)
        secret = "s3cretSECRETvalue123"
        path = os.path.join(self.state, "blizzard.json")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
        os.write(fd, json.dumps({"clientId": "clientid12345", "clientSecret": secret}).encode())
        os.close(fd)
        code, out = run(self.home, {"op": "load"})
        self.assertEqual(code, 0)
        self.assertTrue(out["blizzard"])
        self.assertNotIn(secret, json.dumps(out))
        self.assertNotIn("clientid12345", json.dumps(out))
        code, out = run(self.home, {"op": "clear_blizzard"})
        self.assertEqual((code, out), (0, {"ok": True, "blizzard": False}))
        self.assertFalse(os.path.exists(path))

    def test_malformed_credentials_are_ignored(self):
        os.makedirs(self.state, mode=0o700)
        fd = os.open(os.path.join(self.state, "blizzard.json"), os.O_WRONLY | os.O_CREAT, 0o600)
        os.write(fd, b'{"clientId":"x","clientSecret":"has spaces in it"}')
        os.close(fd)
        _code, out = run(self.home, {"op": "load"})
        self.assertFalse(out["blizzard"])

    def test_set_blizzard_rejects_shape_without_network(self):
        code, out = run(self.home, {"op": "set_blizzard", "clientId": "short", "clientSecret": "has spaces here"})
        self.assertNotEqual(code, 0)
        self.assertIn("develop.battle.net", out["error"])
        self.assertFalse(os.path.exists(os.path.join(self.state, "blizzard.json")))

    def test_rejects_argv_and_unknown_ops(self):
        proc = subprocess.run(["/usr/bin/python3", "-I", "-S", "-B", OPS, "--evil"], input=b'{"op":"load"}',
                              capture_output=True, timeout=30)
        self.assertNotEqual(proc.returncode, 0)
        code, out = run(self.home, {"op": "rm -rf"})
        self.assertNotEqual(code, 0)
        self.assertEqual(out["error"], "Unknown operation")


if __name__ == "__main__":
    unittest.main(verbosity=1)
