"""Testes unitários do scripts/restore_test.py (stdlib apenas). Rodar: python3 -m unittest discover -s tests -p 'test_*.py'"""
import importlib.util
import pathlib
import unittest

_spec = importlib.util.spec_from_file_location(
    "restore_test", pathlib.Path(__file__).resolve().parent.parent / "scripts" / "restore_test.py")
rt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rt)

DUMP = """-- ------------------------------
-- OPTION
-- ------------------------------
OPTION IMPORT;
-- ------------------------------
-- FUNCTIONS
-- ------------------------------
DEFINE FUNCTION fn::text_search($q: string) { LET $a = [1, 2]; RETURN [{ x: $a }]; } PERMISSIONS FULL;
-- ------------------------------
-- TABLE: doc
-- ------------------------------
DEFINE TABLE doc TYPE NORMAL SCHEMAFULL PERMISSIONS NONE;
DEFINE FIELD tags ON doc TYPE array<string> DEFAULT [] PERMISSIONS FULL;
DEFINE INDEX doc_hnsw ON doc FIELDS embedding HNSW DIMENSION 3 DIST COSINE TYPE F32 EFC 150 M 12;
-- ------------------------------
-- TABLE DATA: doc
-- ------------------------------
INSERT [ { embedding: [1.0f, 0.0f], id: doc:1, meta: { a: { b: 1 } }, note: 'has { brace; and [x]' },
{ embedding: [0.0f, 1.0f], id: doc:2, note: "-- not a section" } ];
INSERT [ { id: doc:3 } ];
-- ------------------------------
-- TABLE: empty
-- ------------------------------
DEFINE TABLE empty TYPE NORMAL SCHEMALESS PERMISSIONS NONE;
-- ------------------------------
-- TABLE DATA: empty
-- ------------------------------
-- ------------------------------
-- TABLE: follows
-- ------------------------------
DEFINE TABLE follows TYPE RELATION IN doc OUT doc SCHEMALESS PERMISSIONS NONE;
-- ------------------------------
-- TABLE DATA: follows
-- ------------------------------
INSERT RELATION [ { id: follows:1, in: doc:1, out: doc:2 } ];
"""


class DumpCounts(unittest.TestCase):
    def test_counts_top_level_objects_per_table(self):
        self.assertEqual(rt.dump_counts(DUMP), {"doc": 3, "empty": 0, "follows": 1})

    def test_schema_brackets_and_function_bodies_are_not_records(self):
        counts = rt.dump_counts(DUMP)
        self.assertNotIn("FUNCTIONS", counts)
        self.assertEqual(counts["doc"], 3)

    def test_a_later_non_table_section_stops_counting(self):
        text = DUMP + "-- ------------------------------\n-- FUNCTIONS\n-- ------------------------------\n" \
            "DEFINE FUNCTION fn::f() { RETURN [{ a: 1 }]; };\nINSERT [ { id: stray:1 } ];\n"
        self.assertEqual(rt.dump_counts(text)["follows"], 1)

    def test_truncated_dump_is_an_error(self):
        with self.assertRaises(rt.CheckError):
            rt.dump_counts(DUMP + "\n-- TABLE DATA: x\nINSERT [ { id: x:1 ")


class DumpDefines(unittest.TestCase):
    def test_functions_indexes_and_hnsw(self):
        defines, hnsw = rt.dump_defines(DUMP)
        self.assertEqual(defines["FUNCTION"], {"text_search"})
        self.assertEqual(defines["INDEX"], {"doc_hnsw"})
        self.assertEqual(hnsw, [("doc_hnsw", "doc", "embedding")])


class Throwaway(unittest.TestCase):
    def test_only_restore_namespaces(self):
        rt.throwaway("restore_kubo_test")
        for ns in ("kubo", "obo", "restore", "restore_x;REMOVE", "restore-x"):
            with self.assertRaises(rt.CheckError):
                rt.throwaway(ns)


if __name__ == "__main__":
    unittest.main()
