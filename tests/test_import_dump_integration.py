"""Integração do scripts/import_dump.py contra um SurrealDB v3.3.0 real (Docker local, surrealkv).
Pula se não houver docker. Rodar: python3 -m unittest discover -s tests -p 'test_*.py'"""
import base64
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "import_dump.py"
IMAGE = "surrealdb/surrealdb:v3.3.0"
ROOT_PASS = "it-root-pass"
NS, DB = "proj", "prd"

# Ordem do dump propositalmente ruim: aresta ENFORCED (follows) ANTES dos nós (person); índice no meio.
DUMP = """-- ------------------------------
-- OPTION
-- ------------------------------

OPTION IMPORT;

-- TABLE: doc
DEFINE TABLE doc TYPE NORMAL SCHEMAFULL PERMISSIONS NONE;
DEFINE FIELD OVERWRITE embedding ON doc TYPE array<float> PERMISSIONS FULL;
DEFINE FIELD OVERWRITE embedding[*] ON doc TYPE float PERMISSIONS FULL;
DEFINE FIELD OVERWRITE note ON doc TYPE string PERMISSIONS FULL;
DEFINE INDEX doc_hnsw ON doc FIELDS embedding HNSW DIMENSION 3 DIST COSINE TYPE F32 EFC 150 M 12;

-- TABLE DATA: doc
INSERT [ { embedding: [1.0f, 0.0f, 0.0f], id: doc:1, note: 'has; semicolon and it\\'s quoted' }, { embedding: [0.0f, 1.0f, 0.0f], id: doc:2, note: 'line1;
line2' } ];

-- TABLE: follows
DEFINE TABLE follows TYPE RELATION IN person OUT person ENFORCED SCHEMAFULL PERMISSIONS NONE;
DEFINE FIELD OVERWRITE in ON follows TYPE record<person> PERMISSIONS FULL;
DEFINE FIELD OVERWRITE out ON follows TYPE record<person> PERMISSIONS FULL;

-- TABLE DATA: follows
INSERT RELATION [ { id: follows:1, in: person:alice, out: person:bob } ];

-- TABLE: person
DEFINE TABLE person TYPE NORMAL SCHEMALESS PERMISSIONS NONE;

-- TABLE DATA: person
INSERT [ { id: person:alice }, { id: person:bob } ];

-- FUNCTIONS
DEFINE FUNCTION fn::double($x: int) {
  LET $y = $x * 2;
  RETURN $y;
};

-- exports antigos envolvem tudo em transação
DEFINE TABLE legacy SCHEMALESS;
BEGIN TRANSACTION;
INSERT [ { id: legacy:1, a: 1 } ];
COMMIT TRANSACTION;

-- armadilhas: não podem ser aplicadas
DEFINE USER attacker ON DATABASE PASSWORD 'x' ROLES OWNER;
DEFINE USER app_x ON DATABASE PASSWORD 'hijacked' ROLES OWNER;
"""


def _docker_ok():
    try:
        return subprocess.run(["docker", "info"], capture_output=True, timeout=20).returncode == 0
    except Exception:
        return False


@unittest.skipUnless(shutil.which("docker") and _docker_ok(), "docker indisponível")
class ImportDumpIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.name = "sdb-import-it-%d" % id(cls)
        data = pathlib.Path(cls.tmp) / "data"
        data.mkdir()
        data.chmod(0o777)
        subprocess.run(["docker", "run", "-d", "--name", cls.name, "-p", "127.0.0.1::8000",
                        "-e", "SURREAL_USER=root", "-e", "SURREAL_PASS=" + ROOT_PASS, "-v", "%s:/data" % data,
                        IMAGE, "start", "--no-banner", "--bind", "0.0.0.0:8000", "surrealkv:///data/db"],
                       check=True, capture_output=True)
        port = subprocess.check_output(["docker", "port", cls.name, "8000/tcp"]).decode().split(":")[-1].strip()
        cls.endpoint = "http://127.0.0.1:%s" % port
        for _ in range(60):
            if subprocess.run(["docker", "exec", cls.name, "/surreal", "is-ready", "--endpoint",
                               "http://127.0.0.1:8000"], capture_output=True).returncode == 0:
                break
            subprocess.run(["sleep", "1"])
        cls.root_auth = "Basic " + base64.b64encode(("root:" + ROOT_PASS).encode()).decode()

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["docker", "rm", "-f", cls.name], capture_output=True)
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def sql(self, query, ns=NS, db=DB):
        req = urllib.request.Request(self.endpoint + "/sql", data=query.encode(), method="POST", headers={
            "Authorization": self.root_auth, "surreal-ns": ns, "surreal-db": db, "Accept": "application/json"})
        return json.loads(urllib.request.urlopen(req, timeout=30).read())

    def fresh_db(self, db):
        self.sql("DEFINE NAMESPACE IF NOT EXISTS %s; USE NS %s; DEFINE DATABASE IF NOT EXISTS %s;" % (NS, NS, db),
                 ns=NS, db=db)
        self.sql("DEFINE USER app_x ON DATABASE PASSWORD 'original' ROLES OWNER;", db=db)

    def run_tool(self, dump_text, db, *extra):
        path = pathlib.Path(self.tmp) / ("dump-%s.surql" % db)
        path.write_text(dump_text, encoding="utf-8")
        env = {"SURREAL_ENDPOINT": self.endpoint, "SURREAL_USER": "root", "SURREAL_PASS": ROOT_PASS, "PATH": "/usr/bin:/bin"}
        return subprocess.run(["python3", str(SCRIPT), str(path), NS, db, *extra], capture_output=True, text=True, env=env)

    def count(self, table, db):
        r = self.sql("SELECT count() FROM %s GROUP ALL;" % table, db=db)[0]
        return r["result"][0]["count"] if r["result"] else 0

    _full = None

    def full_import(self):
        """Importa o DUMP completo em `full` uma única vez (testes não dependem de ordem)."""
        cls = type(self)
        if cls._full is None:
            self.fresh_db("full")
            cls._full = self.run_tool(DUMP, "full")
        return cls._full

    def test_imports_out_of_order_dump_in_dependency_order(self):
        res = self.full_import()
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.count("person", "full"), 2)
        self.assertEqual(self.count("follows", "full"), 1, "aresta ENFORCED deve entrar depois dos nós")
        self.assertEqual(self.count("doc", "full"), 2)
        self.assertEqual(self.count("legacy", "full"), 1)

    def test_preserves_tricky_string_content(self):
        self.full_import()
        notes = self.sql("SELECT VALUE note FROM doc ORDER BY id;", db="full")[0]["result"]
        self.assertEqual(notes, ["has; semicolon and it's quoted", "line1;\nline2"])

    def test_multiline_function_and_hnsw_index_work(self):
        self.full_import()
        self.assertEqual(self.sql("RETURN fn::double(21);", db="full")[0]["result"], 42)
        knn = self.sql("SELECT id FROM doc WHERE embedding <|1,40|> [1.0f, 0.0f, 0.0f];", db="full")[0]["result"]
        self.assertEqual(str(knn[0]["id"]), "doc:1")

    def test_dump_users_never_override_existing_users(self):
        self.full_import()
        info = self.sql("INFO FOR DB;", db="full")[0]["result"]
        self.assertNotIn("attacker", info["users"])
        self.assertIn("app_x", info["users"])
        out = subprocess.run(["docker", "exec", "-i", self.name, "/surreal", "sql", "--endpoint",
                              "http://127.0.0.1:8000", "--hide-welcome", "--user", "app_x", "--pass", "original",
                              "--auth-level", "database", "--ns", NS, "--db", "full"],
                             input="RETURN 'login-ok';", capture_output=True, text=True)
        self.assertIn("login-ok", out.stdout, "senha original de app_x deveria seguir válida")

    def test_output_never_contains_password_and_warns_about_protected(self):
        self.fresh_db("quiet")
        res = self.run_tool(DUMP, "quiet")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertNotIn(ROOT_PASS, res.stdout + res.stderr)
        self.assertIn("protegido", res.stdout + res.stderr)

    def test_unknown_statement_aborts_with_exit_2_and_imports_nothing(self):
        self.fresh_db("bad")
        res = self.run_tool("DEFINE TABLE t SCHEMALESS;\nDELETE t;\n", "bad")
        self.assertEqual(res.returncode, 2, res.stdout + res.stderr)
        self.assertEqual(self.sql("INFO FOR DB;", db="bad")[0]["result"]["tables"], {})

    def test_server_error_stops_with_exit_1(self):
        # OPTION IMPORT desliga validação de tipo, então o erro real aqui é id duplicado (o /import só
        # devolve algo no corpo quando há erro; sucesso volta `[]`).
        self.fresh_db("err")
        dump = "DEFINE TABLE t SCHEMALESS;\nINSERT [ { id: t:1, a: 1 } ];\nINSERT [ { id: t:1, a: 2 } ];\n"
        res = self.run_tool(dump, "err")
        self.assertEqual(res.returncode, 1, res.stdout + res.stderr)
        self.assertIn("already exists", res.stdout + res.stderr)

    def test_update_statement_aborts_instead_of_silently_losing_data(self):
        self.fresh_db("upd")
        res = self.run_tool("DEFINE TABLE t SCHEMALESS;\nUPDATE t:1 CONTENT { a: 1 };\n", "upd")
        self.assertEqual(res.returncode, 2, res.stdout + res.stderr)
        self.assertIn("UPSERT", res.stdout + res.stderr)
        self.assertEqual(self.sql("INFO FOR DB;", db="upd")[0]["result"]["tables"], {})

    def test_dry_run_prints_plan_and_touches_nothing(self):
        self.fresh_db("dry")
        res = self.run_tool(DUMP, "dry", "--dry-run")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        for phase in ("schema", "data", "relation", "index"):
            self.assertIn(phase, res.stdout)
        self.assertEqual(self.sql("INFO FOR DB;", db="dry")[0]["result"]["tables"], {})


if __name__ == "__main__":
    unittest.main()
