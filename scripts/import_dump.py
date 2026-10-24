#!/usr/bin/env python3
"""Importa um dump .surql (surreal export) em ordem de dependência, via POST /import.

Por que existe: o dump vem em ordem alfabética de tabela (arestas antes dos nós, índices no meio) e o
`surreal import` de arquivo único travou o RocksDB com os dados do kubo. Aqui o dump é separado em statements
(conscientes de strings, chaves e comentários) e enviado em fases: schema -> dados -> arestas -> índices,
em lotes por tamanho.

Segurança: statements DEFINE USER/ACCESS/TOKEN/SCOPE do dump são IGNORADOS (não sobrescrevem os usuários do
central) e um statement desconhecido aborta ANTES de enviar qualquer coisa (inclusive UPDATE, que no v3 não cria
registro). Nenhuma senha é impressa.

Atenção: `OPTION IMPORT` desliga coerção de tipo e checagem ENFORCED, e o /import responde `[]` no sucesso (só
traz corpo quando há erro). Por isso SEMPRE confira contagem por tabela origem x destino depois.

Uso:
  SURREAL_ENDPOINT=http://10.173.117.50:8000 SURREAL_PASS=... ./scripts/import_dump.py dump.surql <ns> <db>
  ./scripts/import_dump.py dump.surql <ns> <db> --dry-run      # só mostra o plano
"""
import argparse
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

PHASES = ("schema", "data", "relation", "index")

# Strings ('..', "..", `..`, ⟨..⟩), delimitadores estruturais e comentários `--`.
_TOKEN = re.compile(
    r"""'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|`(?:\\.|[^`\\])*`|⟨[^⟩]*⟩|[{}()\[\];]|--[^\n]*""", re.S)


def split_statements(text):
    """Divide o dump em statements. `;` só separa fora de strings e fora de {} () []."""
    out, start, depth = [], 0, 0
    for m in _TOKEN.finditer(text):
        tok = m.group()
        head = tok[0]
        if head in "'\"`⟨":
            continue
        if tok.startswith("--"):
            if depth == 0 and not text[start:m.start()].strip():
                start = m.end()  # comentário na fronteira entre statements
            continue
        if head in "{([":
            depth += 1
        elif head in "})]":
            depth -= 1
        elif head == ";" and depth == 0:
            stmt = text[start:m.end()].strip()
            if stmt:
                out.append(stmt)
            start = m.end()
    tail = text[start:].strip()
    if tail:
        out.append(tail)
    if depth != 0:
        raise ValueError("dump desbalanceado (chaves/colchetes/aspas): truncado ou corrompido?")
    return out


_SKIP = re.compile(r"(OPTION|BEGIN|COMMIT|CANCEL|USE)\b|DEFINE\s+(NAMESPACE|DATABASE|NS|DB)\b")
_PROTECTED = re.compile(r"DEFINE\s+(USER|ACCESS|TOKEN|SCOPE)\b")
_INDEX = re.compile(r"DEFINE\s+INDEX\b")
_DEFINE = re.compile(r"DEFINE\b")
_RELATION = re.compile(r"(INSERT\s+(IGNORE\s+)?RELATION|RELATE)\b")
_DATA = re.compile(r"(INSERT|CREATE|UPSERT)\b")  # UPDATE fora: no v3 não cria registro (perda silenciosa)


def classify(stmt):
    """skip | protected | schema | index | relation | data | unknown."""
    head = stmt[:80].lstrip().upper()
    for pattern, kind in ((_SKIP, "skip"), (_PROTECTED, "protected"), (_INDEX, "index"), (_DEFINE, "schema"),
                          (_RELATION, "relation"), (_DATA, "data")):
        if pattern.match(head):
            return kind
    return "unknown"


def make_plan(statements):
    """Agrupa em fases (ordem preservada dentro de cada uma). Devolve (plano, avisos)."""
    plan = {phase: [] for phase in PHASES}
    warnings, unknown = [], []
    for stmt in statements:
        kind = classify(stmt)
        if kind == "skip":
            continue
        if kind == "protected":
            warnings.append("ignorado (protegido): " + " ".join(stmt.split()[:3]))
        elif kind == "unknown":
            hint = " (UPDATE não cria registro no v3 e o /import responde sucesso: converta para UPSERT)" \
                if stmt.lstrip()[:6].upper() == "UPDATE" else ""
            unknown.append(stmt[:60] + hint)
        else:
            plan[kind].append(stmt)
    if unknown:
        raise ValueError("statement(s) não reconhecido(s), nada foi enviado: " + " | ".join(unknown[:5]))
    return plan, warnings


def make_batches(statements, max_bytes):
    """Agrupa statements consecutivos em lotes de até max_bytes; um statement maior que o limite fica sozinho."""
    batches, current, size = [], [], 0
    for stmt in statements:
        n = len(stmt.encode("utf-8"))
        if current and size + n > max_bytes:
            batches.append(current)
            current, size = [], 0
        current.append(stmt)
        size += n
    if current:
        batches.append(current)
    return batches


def post_import(endpoint, auth, ns, db, statements, timeout):
    """Envia um lote para /import. Devolve None se tudo OK, senão uma mensagem curta de erro."""
    body = ("OPTION IMPORT;\n" + "\n".join(statements)).encode("utf-8")
    req = urllib.request.Request(
        endpoint.rstrip("/") + "/import", data=body, method="POST",
        headers={"Authorization": auth, "surreal-ns": ns, "surreal-db": db, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            results = json.loads(resp.read() or b"[]")
    except urllib.error.HTTPError as exc:
        return "HTTP %d: %s" % (exc.code, exc.read()[:200].decode("utf-8", "replace"))
    except Exception as exc:  # timeout, conexão
        return "falha de requisição: %r" % (exc,)
    errors = [r for r in results if isinstance(r, dict) and r.get("status") != "OK"]
    return str(errors[0])[:300] if errors else None


def main(argv=None):
    parser = argparse.ArgumentParser(description="Importa um dump .surql em ordem de dependência (POST /import).")
    parser.add_argument("dump")
    parser.add_argument("namespace")
    parser.add_argument("database")
    parser.add_argument("--endpoint", default=os.environ.get("SURREAL_ENDPOINT"))
    parser.add_argument("--user", default=os.environ.get("SURREAL_USER", "root"))
    parser.add_argument("--batch-bytes", type=int, default=2_000_000, help="tamanho máximo de um lote (default 2 MB)")
    parser.add_argument("--timeout", type=int, default=600, help="timeout por request, em segundos")
    parser.add_argument("--dry-run", action="store_true", help="só mostra o plano; não conecta")
    args = parser.parse_args(argv)

    dump_path = os.path.realpath(args.dump)
    if not dump_path.endswith(".surql") or not os.path.isfile(dump_path):
        print("ERRO: o dump deve ser um arquivo .surql existente: %s" % args.dump, file=sys.stderr)
        return 2
    try:
        with open(dump_path, encoding="utf-8") as fh:
            statements = split_statements(fh.read())
        plan, warnings = make_plan(statements)
    except (OSError, ValueError) as exc:
        print("ERRO: %s" % exc, file=sys.stderr)
        return 2

    for warning in warnings:
        print("aviso: " + warning)
    batches = {phase: make_batches(plan[phase], args.batch_bytes) for phase in PHASES}
    for phase in PHASES:
        print("%-8s %6d statements em %d lote(s)" % (phase, len(plan[phase]), len(batches[phase])))
    if args.dry_run:
        return 0

    password = os.environ.get("SURREAL_PASS")
    if not args.endpoint or not password:
        print("ERRO: defina SURREAL_ENDPOINT (ou --endpoint) e SURREAL_PASS", file=sys.stderr)
        return 2
    auth = "Basic " + base64.b64encode(("%s:%s" % (args.user, password)).encode()).decode()

    started = time.time()
    for phase in PHASES:
        for number, batch in enumerate(batches[phase], 1):
            t0 = time.time()
            error = post_import(args.endpoint, auth, args.namespace, args.database, batch, args.timeout)
            if error:
                print("ERRO na fase %s (lote %d/%d): %s" % (phase, number, len(batches[phase]), error), file=sys.stderr)
                return 1
            if time.time() - t0 > 5:
                print("  %s lote %d/%d: %.1fs" % (phase, number, len(batches[phase]), time.time() - t0))
        print("fase %s concluída (%.0fs)" % (phase, time.time() - started))
    print("import concluído em %.0fs" % (time.time() - started))
    return 0


if __name__ == "__main__":
    sys.exit(main())
