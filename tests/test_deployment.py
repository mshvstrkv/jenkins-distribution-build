import unittest

from scripts.lib.distribution.deployment import determine_deployment_mode


class DeploymentTests(unittest.TestCase):
    def test_modes(self):
        self.assertEqual(determine_deployment_mode(False, False), "create")
        self.assertEqual(determine_deployment_mode(True, True), "update")
        self.assertEqual(determine_deployment_mode(True, False), "inconsistent")
        self.assertEqual(determine_deployment_mode(False, True), "inconsistent")
        self.assertEqual(determine_deployment_mode(None, True), "unknown")


if __name__ == "__main__":
    unittest.main()

