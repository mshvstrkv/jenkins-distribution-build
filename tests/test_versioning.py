import unittest

from scripts.lib.distribution.versioning import (
    normalize_distribution_type,
    resolve_version,
)


class VersioningTests(unittest.TestCase):
    def test_ift_initial(self):
        self.assertEqual(resolve_version("ift", []).version, "IFT-0.0.1")

    def test_ift_increment(self):
        self.assertEqual(resolve_version("ift", ["IFT-0.0.1"]).version, "IFT-0.0.2")
        self.assertEqual(resolve_version("ift", ["IFT-0.1.1"]).version, "IFT-0.1.2")

    def test_ift_ignores_release(self):
        self.assertEqual(resolve_version("ift", ["D-00.000.09"]).version, "IFT-0.0.1")

    def test_release_initial_and_increment(self):
        self.assertEqual(resolve_version("release", []).version, "D-00.000.01")
        self.assertEqual(resolve_version("release", ["D-00.000.01"]).version, "D-00.000.02")
        self.assertEqual(resolve_version("release", ["D-00.000.09"]).version, "D-00.000.10")

    def test_release_overflow(self):
        with self.assertRaises(OverflowError):
            resolve_version("release", ["D-00.000.99"])

    def test_release_ignores_ift(self):
        self.assertEqual(resolve_version("release", ["IFT-0.1.2"]).version, "D-00.000.01")

    def test_aliases(self):
        self.assertEqual(normalize_distribution_type("test"), "ift")
        self.assertEqual(normalize_distribution_type("testing"), "ift")
        self.assertEqual(normalize_distribution_type("prod"), "release")
        self.assertEqual(normalize_distribution_type("production"), "release")


if __name__ == "__main__":
    unittest.main()

