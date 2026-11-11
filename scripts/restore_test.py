#!/usr/bin/env python3
"""Teste de restore de um backup do central (gate do ADR-0015 no oute-infra-ops).

Restaura um export .surql (o que o surreal-platform guarda no restic) num namespace descartável e confere o
restaurado contra o PRÓPRIO dump, não contra a origem viva (que muda depois do backup):
contagem de registros por tabela, conjunto de tabelas, DEFINE FUNCTION e DEFINE INDEX, e um KNN se houver HNSW.

  restore_test.py prepare NS DB          cria NS/DB vazios (NS precisa começar com restore_)
  (importar com scripts/import_dump.py DUMP NS DB)
  restore_test.py verify DUMP NS DB      confere; exit 1 se divergir
  restore_test.py drop NS                remove o namespace descartável (só restore_*)
  restore_test.py counts DUMP NS DB      só leitura, qualquer ns/db: registros por tabela dump x destino

Roda DENTRO do LXC, como root do SurrealDB: SURREAL_ENDPOINT, SURREAL_PASS (e SURREAL_USER, padrão root).
Nenhuma senha é impressa. Só toca namespaces restore_*: o resto do central é só lido.
"""
import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

PREFIX = "restore_"
NAME = re.compile(r"^[A-Za-z0-9_]+$")
# Mesmos tokens do import_dump: strings não contam como estrutura; comentários marcam as seções do export.
_TOKEN = re.compile(
    r"""'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|`(?:\\.|[^`\\])*`|⟨[^⟩]*⟩|[{}()\[\];]|--[^\n]*""", re.S)
_SECTION = re.compile(r"--\s*TABLE( DATA)?:\s*(\S+)")
_HEADER = re.compile(r"--\s*[A-Z][A-Z ]*:?\s*$")
_DEFINE = re.compile(r"^DEFINE (FUNCTION|INDEX) (?:OVERWRITE |IF NOT EXISTS )?(\S+)", re.M)
_HNSW = re.compile(r"^DEFINE INDEX (?:OVERWRITE |IF NOT EXISTS )?(\S+) ON (?:TABLE )?(\S+) FIELDS (\S+) HNSW", re.M)


class CheckError(Exception):
    pass


def dump_counts(text):
    """Registros por tabela no export: objetos no nível de cima dos INSERT de cada seção TABLE DATA."""
    counts, table, stack = {}, None, []
    for m in _TOKEN.finditer(text):
        tok = m.group()
        if tok.startswith("--"):
            if stack:
                continue
            section = _SECTION.match(tok)
            if section:
                table = section.group(2) if section.group(1) else None
                if table:
                    counts.setdefault(table, 0)
            elif _HEADER.match(tok):
                table = None  # outra seção do export (FUNCTIONS, ANALYZERS...): não é dado
            continue
        head = tok[0]
        if head in "'\"`⟨" or table is None:
            continue
        if head in "[{(":
            if head == "{" and stack == ["["]:
                counts[table] += 1
            stack.append(head)
        elif head in "]})":
            if not stack:
                raise CheckError("dump desbalanceado: truncado ou corrompido?")
            stack.pop()
    if stack:
        raise CheckError("dump desbalanceado: truncado ou corrompido?")
    return counts


def dump_defines(text):
    """Nomes de DEFINE FUNCTION e DEFINE INDEX, e os índices HNSW (nome, tabela, campo)."""
    found = {"FUNCTION": set(), "INDEX": set()}
    for kind, name in _DEFINE.findall(text):
        found[kind].add(name.split("(")[0].removeprefix("fn::"))
    return found, _HNSW.findall(text)


def client(ns=None, db=None):
    endpoint = os.environ.get("SURREAL_ENDPOINT", "")
    password = os.environ.get("SURREAL_PASS", "")
    if not endpoint or not password:
        raise CheckError("defina SURREAL_ENDPOINT e SURREAL_PASS")
    user = os.environ.get("SURREAL_USER", "root")
    auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()

    def query(sql):
        headers = {"Authorization": auth, "Accept": "application/json"}
        if ns:
            headers["surreal-ns"] = ns
        if db:
            headers["surreal-db"] = db
        req = urllib.request.Request(endpoint.rstrip("/") + "/sql", data=sql.encode(), method="POST",
                                     headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                results = json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            raise CheckError("HTTP %d: %s" % (exc.code, exc.read()[:200].decode("utf-8", "replace"))) from exc
        bad = [r for r in results if r.get("status") != "OK"]
        if bad:
            raise CheckError(str(bad[0].get("result"))[:300])
        return [r.get("result") for r in results]

    return query


def throwaway(ns):
    if not (ns.startswith(PREFIX) and NAME.match(ns)):
        raise CheckError(f"só namespaces {PREFIX}* (recebi {ns!r})")


def prepare(ns, db):
    throwaway(ns)
    if not NAME.match(db):
        raise CheckError(f"database inválida: {db!r}")
    client()(f"DEFINE NAMESPACE IF NOT EXISTS {ns}; USE NS {ns}; DEFINE DATABASE IF NOT EXISTS {db};")
    tables = client(ns, db)("INFO FOR DB;")[0]["tables"]
    if tables:
        raise CheckError(f"{ns}/{db} já tem {len(tables)} tabela(s): rode drop antes")
    print(f"  [ok]    {ns}/{db} criado e vazio")


def verify(dump_path, ns, db):
    throwaway(ns)
    with open(dump_path, encoding="utf-8") as fh:
        text = fh.read()
    expected = dump_counts(text)
    defines, hnsw = dump_defines(text)
    query = client(ns, db)
    info = query("INFO FOR DB;")[0]
    tables = sorted(info["tables"])
    problems = []

    missing = sorted(set(expected) - set(tables))
    extra = sorted(set(tables) - set(expected))
    if missing:
        problems.append("tabelas faltando: " + ", ".join(missing[:10]))
    if extra:
        problems.append("tabelas a mais: " + ", ".join(extra[:10]))

    present = sorted(set(expected) & set(tables))
    got = {}
    if present:
        results = query("".join(f"SELECT count() FROM {t} GROUP ALL;" for t in present))
        got = {t: (r[0]["count"] if r else 0) for t, r in zip(present, results)}
    diffs = [(t, expected[t], got[t]) for t in present if expected[t] != got[t]]
    for t, want, have in diffs[:10]:
        problems.append(f"{t}: dump={want} restaurado={have}")

    functions = set(info.get("functions", {}))
    if defines["FUNCTION"] - functions:
        problems.append("funções faltando: " + ", ".join(sorted(defines["FUNCTION"] - functions)))
    indexes = set()
    for t in present:
        indexes |= set(query(f"INFO FOR TABLE {t};")[0].get("indexes", {}))
    if defines["INDEX"] - indexes:
        problems.append("índices faltando: " + ", ".join(sorted(defines["INDEX"] - indexes)[:10]))

    total_want, total_have = sum(expected.values()), sum(got.values())
    print(f"  tabelas={len(expected)} registros dump={total_want} restaurado={total_have} "
          f"funções={len(defines['FUNCTION'])} índices={len(defines['INDEX'])}")

    for name, table, field in hnsw:
        if got.get(table):
            res = query(f"LET $v = (SELECT VALUE {field} FROM {table} LIMIT 1)[0]; "
                        f"SELECT id FROM {table} WHERE {field} <|3,40|> $v;")[-1]
            if not res:
                problems.append(f"KNN sem resultado em {name}")
            else:
                print(f"  [ok]    KNN em {name} ({table}.{field}): {len(res)} vizinhos")
            break

    if problems:
        for p in problems:
            print("  [ERRO]  " + p)
        return 1
    print(f"  [ok]    restore de {dump_path} confere com o dump")
    return 0


def counts(dump_path, ns, db):
    """Só leitura, em qualquer ns/db: registros por tabela do dump x destino (tabelas a mais no destino
    não contam: podem ser do app). Usado para conferir uma migração de dados (import --data-only)."""
    if not (NAME.match(ns) and NAME.match(db)):
        raise CheckError("ns/db precisam ser identificadores simples")
    with open(dump_path, encoding="utf-8") as fh:
        expected = dump_counts(fh.read())
    query = client(ns, db)
    tables = set(query("INFO FOR DB;")[0]["tables"])
    missing = sorted(set(expected) - tables)
    present = sorted(set(expected) & tables)
    got = {}
    if present:
        results = query("".join(f"SELECT count() FROM {t} GROUP ALL;" for t in present))
        got = {t: (r[0]["count"] if r else 0) for t, r in zip(present, results)}
    diffs = [(t, expected[t], got[t]) for t in present if expected[t] != got[t]]
    print(f"  tabelas={len(expected)} registros dump={sum(expected.values())} destino={sum(got.values())}")
    for t in missing:
        if expected[t]:
            diffs.append((t, expected[t], "tabela ausente"))
    for t, want, have in diffs:
        print(f"  [ERRO]  {t}: dump={want} destino={have}")
    if not diffs:
        print(f"  [ok]    {ns}/{db} confere com {dump_path}")
    return 1 if diffs else 0


def drop(ns):
    throwaway(ns)
    client()(f"REMOVE NAMESPACE IF EXISTS {ns};")
    print(f"  [ok]    {ns} removido")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Teste de restore de um backup do central (ADR-0015).")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("ns")
    p.add_argument("db")
    v = sub.add_parser("verify")
    v.add_argument("dump")
    v.add_argument("ns")
    v.add_argument("db")
    c = sub.add_parser("counts")
    c.add_argument("dump")
    c.add_argument("ns")
    c.add_argument("db")
    d = sub.add_parser("drop")
    d.add_argument("ns")
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            prepare(args.ns, args.db)
        elif args.command == "verify":
            return verify(args.dump, args.ns, args.db)
        elif args.command == "counts":
            return counts(args.dump, args.ns, args.db)
        else:
            drop(args.ns)
    except (CheckError, OSError) as exc:
        print("ERRO: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
