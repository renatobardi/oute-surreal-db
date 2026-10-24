"""Testes unitários do scripts/import_dump.py (stdlib apenas). Rodar: python3 -m unittest discover -s tests -p 'test_*.py'"""
import importlib.util
import pathlib
import unittest

_spec = importlib.util.spec_from_file_location(
    "import_dump", pathlib.Path(__file__).resolve().parent.parent / "scripts" / "import_dump.py")
imp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(imp)


class SplitStatements(unittest.TestCase):
    def test_two_simple_statements(self):
        self.assertEqual(imp.split_statements("DEFINE TABLE a;\nDEFINE TABLE b;\n"),
                         ["DEFINE TABLE a;", "DEFINE TABLE b;"])

    def test_semicolon_inside_each_kind_of_quote(self):
        text = "INSERT [{a:'x;y'}];\nINSERT [{a:\"x;y\"}];\nINSERT [{`a;b`: 1}];\nINSERT [{⟨a;b⟩: 1}];"
        self.assertEqual(len(imp.split_statements(text)), 4)

    def test_escaped_quote_does_not_close_string(self):
        stmts = imp.split_statements("INSERT [{a:'it\\'s; fine'}];\nDEFINE TABLE b;")
        self.assertEqual(len(stmts), 2)
        self.assertIn("it\\'s; fine", stmts[0])

    def test_multiline_string_with_semicolon_and_newline(self):
        stmts = imp.split_statements("INSERT [{a:'line1;\nline2'}];\nDEFINE TABLE b;")
        self.assertEqual(len(stmts), 2)
        self.assertIn("line1;\nline2", stmts[0])

    def test_comment_lines_between_statements_are_dropped(self):
        text = "-- ------\n-- TABLE: a\n-- ------\n\nDEFINE TABLE a;\n\n-- TABLE DATA: a\nINSERT [{a:1}];\n"
        self.assertEqual(imp.split_statements(text), ["DEFINE TABLE a;", "INSERT [{a:1}];"])

    def test_double_dash_inside_a_string_is_not_a_comment(self):
        self.assertEqual(imp.split_statements("INSERT [{a:'-- not a comment;'}];"),
                         ["INSERT [{a:'-- not a comment;'}];"])

    def test_function_body_with_inner_semicolons_is_one_statement(self):
        fn = "DEFINE FUNCTION fn::f($x: int) {\n  LET $y = $x + 1;\n  RETURN $y;\n};"
        stmts = imp.split_statements(fn + "\nDEFINE TABLE b;")
        self.assertEqual(len(stmts), 2)
        self.assertEqual(stmts[0], fn)

    def test_last_statement_without_semicolon_is_kept(self):
        self.assertEqual(imp.split_statements("DEFINE TABLE a;\nDEFINE TABLE b"),
                         ["DEFINE TABLE a;", "DEFINE TABLE b"])


class Classify(unittest.TestCase):
    CASES = {
        "OPTION IMPORT;": "skip",
        "BEGIN TRANSACTION;": "skip",
        "COMMIT TRANSACTION;": "skip",
        "USE NS a DB b;": "skip",
        "DEFINE NAMESPACE a;": "skip",
        "DEFINE DATABASE b;": "skip",
        "DEFINE USER app ON DATABASE PASSWORD 'x' ROLES OWNER;": "protected",
        "DEFINE ACCESS a ON DATABASE TYPE JWT ALGORITHM HS256 KEY 'k';": "protected",
        "DEFINE TABLE t TYPE NORMAL SCHEMAFULL;": "schema",
        "DEFINE FIELD OVERWRITE f ON t TYPE string;": "schema",
        "DEFINE FUNCTION fn::f() { RETURN 1; };": "schema",
        "DEFINE ANALYZER a TOKENIZERS blank;": "schema",
        "DEFINE EVENT e ON t WHEN true THEN { RETURN 1; };": "schema",
        "DEFINE INDEX i ON t FIELDS f UNIQUE;": "index",
        "define index i on t fields f;": "index",
        "INSERT [{id: t:1}];": "data",
        "INSERT IGNORE INTO t [{id: t:1}];": "data",
        "UPDATE t:1 CONTENT {a: 1};": "unknown",  # no v3 não cria o registro: perda silenciosa
        "CREATE t:1 SET a = 1;": "data",
        "UPSERT t:1 SET a = 1;": "data",
        "INSERT RELATION [{in: a:1, out: b:1}];": "relation",
        "RELATE a:1->r->b:1;": "relation",
        "DELETE t;": "unknown",
        "REMOVE TABLE t;": "unknown",
    }

    def test_classification(self):
        for stmt, expected in self.CASES.items():
            with self.subTest(stmt=stmt):
                self.assertEqual(imp.classify(stmt), expected)


class MakePlan(unittest.TestCase):
    def test_phases_are_schema_data_relation_index_preserving_order(self):
        stmts = ["OPTION IMPORT;", "DEFINE INDEX i ON t FIELDS f;", "INSERT RELATION [{in:a:1,out:b:1}];",
                 "INSERT [{id:t:1}];", "DEFINE TABLE t;", "INSERT [{id:t:2}];", "DEFINE FIELD f ON t TYPE string;"]
        plan, warnings = imp.make_plan(stmts)
        self.assertEqual(list(plan), ["schema", "data", "relation", "index"])
        self.assertEqual(plan["schema"], ["DEFINE TABLE t;", "DEFINE FIELD f ON t TYPE string;"])
        self.assertEqual(plan["data"], ["INSERT [{id:t:1}];", "INSERT [{id:t:2}];"])
        self.assertEqual(plan["relation"], ["INSERT RELATION [{in:a:1,out:b:1}];"])
        self.assertEqual(plan["index"], ["DEFINE INDEX i ON t FIELDS f;"])
        self.assertEqual(warnings, [])

    def test_protected_statements_are_excluded_and_reported(self):
        plan, warnings = imp.make_plan(["DEFINE TABLE t;", "DEFINE USER app ON DATABASE PASSWORD 'x' ROLES OWNER;"])
        self.assertEqual(plan["schema"], ["DEFINE TABLE t;"])
        self.assertEqual(len(warnings), 1)
        self.assertIn("DEFINE USER", warnings[0])
        self.assertNotIn("password", warnings[0].lower().replace("password 'x'", ""))

    def test_update_is_rejected_with_an_explanation(self):
        with self.assertRaises(ValueError) as ctx:
            imp.make_plan(["UPDATE t:1 CONTENT {a: 1};"])
        self.assertIn("UPSERT", str(ctx.exception))

    def test_unknown_statement_aborts_before_anything_is_planned(self):
        with self.assertRaises(ValueError) as ctx:
            imp.make_plan(["DEFINE TABLE t;", "DELETE t;"])
        self.assertIn("DELETE t;", str(ctx.exception))


class MakeBatches(unittest.TestCase):
    def test_groups_until_limit_and_keeps_order(self):
        stmts = ["A" * 10, "B" * 10, "C" * 10, "D" * 10]
        self.assertEqual(imp.make_batches(stmts, 25), [["A" * 10, "B" * 10], ["C" * 10, "D" * 10]])

    def test_oversize_statement_gets_its_own_batch(self):
        stmts = ["a" * 5, "B" * 100, "c" * 5]
        self.assertEqual(imp.make_batches(stmts, 20), [["a" * 5], ["B" * 100], ["c" * 5]])

    def test_empty_input(self):
        self.assertEqual(imp.make_batches([], 100), [])


class MainPathValidation(unittest.TestCase):
    """O caminho do dump vem da linha de comando: só aceita arquivo .surql existente."""

    def run_main(self, path):
        import contextlib
        import io
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = imp.main([str(path), "ns", "db", "--dry-run"])
        return code, err.getvalue()

    def test_rejects_file_without_surql_extension(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            bad = pathlib.Path(tmp) / "passwd.txt"
            bad.write_text("DEFINE TABLE t;")
            code, err = self.run_main(bad)
        self.assertEqual(code, 2)
        self.assertIn(".surql", err)

    def test_rejects_directory_and_missing_path(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            as_dir = pathlib.Path(tmp) / "dump.surql"
            as_dir.mkdir()
            self.assertEqual(self.run_main(as_dir)[0], 2)
            self.assertEqual(self.run_main(pathlib.Path(tmp) / "nao-existe.surql")[0], 2)

    def test_accepts_regular_surql_file(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            ok = pathlib.Path(tmp) / "dump.surql"
            ok.write_text("DEFINE TABLE t;")
            self.assertEqual(self.run_main(ok)[0], 0)


if __name__ == "__main__":
    unittest.main()
