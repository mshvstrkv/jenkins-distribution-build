import unittest

from scripts.lib.distribution.templates import TemplateError, render_path, render_template, validate_relative_path


class TemplateTests(unittest.TestCase):
    def test_render_path(self):
        self.assertEqual(
            render_path("charts/{{PROJECT_NAME}}", {"PROJECT_NAME": "payment-orders"}),
            "charts/payment-orders",
        )

    def test_unknown_placeholder(self):
        with self.assertRaises(TemplateError):
            render_template("charts/{{UNKNOWN}}", {})

    def test_bad_paths(self):
        for path in ["/charts/project", "../charts/project", "charts/project\nbad"]:
            with self.assertRaises(TemplateError):
                validate_relative_path(path)


if __name__ == "__main__":
    unittest.main()

