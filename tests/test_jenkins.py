import unittest

from scripts.lib.distribution.jenkins import (
    map_parameters,
    parameter_names,
    version_candidates_from_builds,
)


class JenkinsTests(unittest.TestCase):
    def test_parameter_definitions(self):
        payload = {"property": [{"parameterDefinitions": [{"name": "BRANCH"}, {"name": "VERSION"}]}]}
        self.assertEqual(parameter_names(payload), ["BRANCH", "VERSION"])

    def test_missing_version_mapping(self):
        mapped = map_parameters(["BRANCH"], "BRANCH", "VERSION", "DISTRIBUTION_TYPE")
        self.assertEqual(mapped["version"], "")

    def test_version_candidates(self):
        payload = {
            "builds": [
                {"displayName": "IFT-0.1.1", "description": "D-00.000.01", "actions": []},
                {"actions": [{"parameters": [{"name": "VERSION", "value": "IFT-0.1.2"}]}]},
            ]
        }
        self.assertEqual(version_candidates_from_builds(payload, "ift"), ["IFT-0.1.1", "IFT-0.1.2"])


if __name__ == "__main__":
    unittest.main()

