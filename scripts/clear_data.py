#!/usr/bin/env python3
"""Apaga os REGISTROS de todas as tabelas de um ns/db e mantém o schema (tabelas, campos, índices, funções).

Para quê: num destino recém-criado pelas migrations de um app, as migrations também gravam dados padrão
(registros singleton, perfis, defaults). Antes de importar os dados reais com `import_dump.py --data-only`,
esses padrões precisam sair, senão duplicam ou colidem com os IDs do dump.

  clear_data.py NS DB --confirm NS/DB     # o --confirm repete o alvo, de propósito

Roda DENTRO do LXC, como root do SurrealDB: SURREAL_ENDPOINT, SURREAL_PASS (e SURREAL_USER, padrão root).
Usuários e acessos do database não são tocados. Nenhuma senha é impressa.
"""
import argparse
import base64
import json
import os
import re
import sys
import urllib.request

NAME = re.compile(r"^[A-Za-z0-9_]+$")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Apaga os registros de um ns/db, mantendo o schema.")
    parser.add_argument("ns")
    parser.add_argument("db")
    parser.add_argument("--confirm", required=True, help="repita NS/DB")
    args = parser.parse_args(argv)
    if not (NAME.match(args.ns) and NAME.match(args.db)) or args.confirm != f"{args.ns}/{args.db}":
        print("ERRO: --confirm precisa ser exatamente NS/DB", file=sys.stderr)
        return 2
    endpoint, password = os.environ.get("SURREAL_ENDPOINT"), os.environ.get("SURREAL_PASS")
    if not endpoint or not password:
        print("ERRO: defina SURREAL_ENDPOINT e SURREAL_PASS", file=sys.stderr)
        return 2
    auth = "Basic " + base64.b64encode(f"{os.environ.get('SURREAL_USER', 'root')}:{password}".encode()).decode()

    def query(sql):
        req = urllib.request.Request(endpoint.rstrip("/") + "/sql", data=sql.encode(), method="POST", headers={
            "Authorization": auth, "surreal-ns": args.ns, "surreal-db": args.db, "Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=600) as resp:
            results = json.loads(resp.read())
        bad = [r for r in results if r.get("status") != "OK"]
        if bad:
            raise RuntimeError(str(bad[0].get("result"))[:300])
        return [r.get("result") for r in results]

    try:
        tables = sorted(query("INFO FOR DB;")[0]["tables"])
        if tables:
            query("".join(f"DELETE {t};" for t in tables))
            left = query("".join(f"SELECT count() FROM {t} GROUP ALL;" for t in tables))
            remaining = sum(r[0]["count"] for r in left if r)
            if remaining:
                raise RuntimeError(f"{remaining} registro(s) sobraram")
    except (OSError, RuntimeError) as exc:
        print("ERRO: %s" % exc, file=sys.stderr)
        return 1
    print(f"  [ok]    {args.ns}/{args.db}: registros de {len(tables)} tabela(s) apagados; schema e usuários mantidos")
    return 0


if __name__ == "__main__":
    sys.exit(main())
