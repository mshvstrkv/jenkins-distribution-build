import unittest

from scripts.lib.distribution.argocd import app_fields


class ArgoTests(unittest.TestCase):
    def test_app_fields(self):
        payload = {
            "metadata": {"name": "app"},
            "spec": {
                "project": "project",
                "source": {"repoURL": "repo", "targetRevision": "main", "path": "path"},
                "destination": {"server": "cluster", "namespace": "ns"},
            },
            "status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}},
        }
        fields = app_fields(payload)
        self.assertEqual(fields["app_name"], "app")
        self.assertEqual(fields["destination_server"], "cluster")
        self.assertEqual(fields["sync_status"], "Synced")
        self.assertEqual(fields["health_status"], "Healthy")


if __name__ == "__main__":
    unittest.main()
