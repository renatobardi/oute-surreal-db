"""Testes unitários do scripts/clear_data.py (stdlib apenas). Rodar: python3 -m unittest discover -s tests -p 'test_*.py'"""
import contextlib
import importlib.util
import io
import os
import pathlib
import unittest
from unittest import mock

_spec = importlib.util.spec_from_file_location(
    "clear_data", pathlib.Path(__file__).resolve().parent.parent / "scripts" / "clear_data.py")
cd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cd)


class Confirm(unittest.TestCase):
    def run_main(self, argv):
        with contextlib.redirect_stderr(io.StringIO()), mock.patch.dict(os.environ, {}, clear=True):
            return cd.main(argv)

    def test_confirm_must_repeat_the_target(self):
        self.assertEqual(self.run_main(["obo", "prd", "--confirm", "obo/test"]), 2)
        self.assertEqual(self.run_main(["obo", "prd", "--confirm", "kubo/prd"]), 2)

    def test_names_must_be_plain_identifiers(self):
        self.assertEqual(self.run_main(["obo;REMOVE", "prd", "--confirm", "obo;REMOVE/prd"]), 2)

    def test_matching_confirm_still_needs_credentials(self):
        self.assertEqual(self.run_main(["obo", "prd", "--confirm", "obo/prd"]), 2)


if __name__ == "__main__":
    unittest.main()
