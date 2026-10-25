#!/usr/bin/env bash
#
# migrate_kubo_data.sh <test|prd> — copia os dados do banco LOCAL do kubo para a instância central e
# CONFERE (contagem por tabela, origem x destino, e KNN em um índice HNSW). Roda no Mac.
#
# O que faz, na ordem (os mesmos passos do cutover do kubo-test, agora em script):
#   1. pré-checagens (ssh, central saudável, banco/sidecar de origem no ar)
#   2. snapshot do LXC do central (rollback do lado do central)
#   3. para scheduler e api do kubo (escritores) — a menos que --no-stop-writers
#   4. exporta o banco local por pipe (sem passar por disco do Mac nem do host)
#   5. limpa o database de destino no central (REMOVE TABLE; os usuários ficam) e importa
#      com scripts/import_dump.py (schema -> dados -> arestas -> índices)
#   6. confere contagem por tabela e KNN; só então apaga o dump do central
# NÃO sobe o kubo no central: isso é o passo seguinte (config do .env + ops/start_kubo_on_central.sh).
# Se a conferência falhar, os escritores continuam parados e o script diz como retomar o banco local.
#
# Uso:
#   ./ops/migrate_kubo_data.sh test --check                          # só pré-checagens
#   ./ops/migrate_kubo_data.sh prd                                   # cutover de dados do kubo-prd
#   ./ops/migrate_kubo_data.sh test --target-db rehearsal --no-stop-writers   # ensaio sem tocar em nada
#
# AVISO (prd): NÃO tire snapshot do LXC kubo-prd. No pool `dir` o snapshot congela a instância por
# minutos. O rollback do prd é: o banco local não é tocado + ~/.env.pre-central.

set -euo pipefail

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
ENVNAME="$1"; shift
case "${ENVNAME}" in test|prd) ;; *) usage ;; esac

HOST="${OUTE_HOST:-oute-server}"
KUBO_LXC="kubo-${ENVNAME}"
CENTRAL="${CENTRAL_LXC:-oute-surreal-db}"
SIDECAR="kubo-backup-1"
NS="kubo"
TARGET_DB="${ENVNAME}"
STOP_WRITERS=1
CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target-db) TARGET_DB="${2:?--target-db precisa de um nome}"; shift 2 ;;
    --no-stop-writers) STOP_WRITERS=0; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    *) usage ;;
  esac
done
DUMP="/root/migrate-${ENVNAME}-${TARGET_DB}.surql"
WORK="$(mktemp -d)"

ok()   { printf '  [ok]    %s\n' "$*"; }
die()  { printf '  [ERRO]  %s\n' "$*" >&2; exit 1; }
step() { printf '\n>> %s\n' "$*"; }
rx() { ssh -o BatchMode=yes -o ConnectTimeout=10 "${HOST}" "$@"; }
kx() { rx "lxc exec ${KUBO_LXC} -- sudo -u ubuntu -H bash -c '$1'" </dev/null; }
cx() { rx "lxc exec ${CENTRAL} -- sh -c '$1'" </dev/null; }
# python dentro do central com a senha root do .env do próprio central (nunca sai de lá)
central_py() { rx "lxc exec ${CENTRAL} -- sh -c 'cd /opt/oute-surreal-db && set -a && . ./.env && set +a && TARGET_DB=${TARGET_DB} python3 -'"; }

cleanup() { rm -rf "${WORK}"; rx "lxc exec ${CENTRAL} -- rm -f ${DUMP}" </dev/null >/dev/null 2>&1 || true; }
trap cleanup EXIT

step "Pré-checagens (${KUBO_LXC} -> ${CENTRAL}, database ${NS}/${TARGET_DB})"
rx true || die "sem ssh para ${HOST}"
ok "ssh ${HOST}"
[ "$(cx 'docker inspect -f "{{.State.Health.Status}}" oute-surreal-db')" = healthy ] || die "central não está healthy"
ok "central healthy"
kx "docker ps --format {{.Names}} | grep -qx ${SIDECAR}" || die "sidecar ${SIDECAR} não está rodando em ${KUBO_LXC} (é de onde se exporta o banco local)"
ok "origem (banco local + sidecar) no ar"
[ "${CHECK_ONLY}" -eq 0 ] || { echo; echo ">> --check concluído; nada foi alterado."; exit 0; }

step "Snapshot do central (rollback do lado do central)"
SNAP="pre-migrate-${ENVNAME}-$(date +%Y%m%d%H%M%S)"
rx "lxc snapshot ${CENTRAL} ${SNAP}" </dev/null
ok "snapshot ${SNAP}"

if [ "${STOP_WRITERS}" -eq 1 ]; then
  step "Parando scheduler e api do ${KUBO_LXC} (escritores)"
  kx 'cd ~/kubo && docker compose stop kubo-api kubo-scheduler' >/dev/null
  ok "escritores parados (o banco local continua no ar, intacto)"
else
  echo "  (--no-stop-writers: ensaio; a origem não será alterada por ninguém durante a cópia)"
fi
RESUME="ssh ${HOST} \"lxc exec ${KUBO_LXC} -- sudo -u ubuntu -H bash -c 'cd ~/kubo && docker compose start kubo-api kubo-scheduler'\""

step "Exportando o banco local -> central (pipe, sem disco intermediário)"
rx "lxc exec ${KUBO_LXC} -- docker exec ${SIDECAR} sh -c 'AUTH=\$(printf \"%s:%s\" \"\$SURREAL_USER\" \"\$SURREAL_PASS\" | base64 | tr -d \"\\n\"); wget -q --timeout=300 -O - --header=\"Authorization: Basic \$AUTH\" --header=\"surreal-ns: \$SURREAL_NS\" --header=\"surreal-db: \$SURREAL_DB\" http://surrealdb:8000/export' </dev/null | lxc exec ${CENTRAL} -- sh -c 'cat > ${DUMP}'"
BYTES="$(cx "stat -c %s ${DUMP}")"
[ "${BYTES}" -gt 1000 ] || die "dump vazio ou truncado (${BYTES} bytes). Para retomar o banco local: ${RESUME}"
TABLES="$(cx "grep -oP \"^DEFINE TABLE \\K\\w+\" ${DUMP}" | tr '\n' ' ')"
ok "dump de ${BYTES} bytes, $(echo "${TABLES}" | wc -w | tr -d ' ') tabelas"

step "Limpando ${NS}/${TARGET_DB} no central e importando"
central_py <<'PY' || die "falha ao preparar o database de destino. Para retomar o banco local: ${RESUME}"
import base64, json, os, urllib.request
db = os.environ["TARGET_DB"]
def q(s):
    r = urllib.request.Request("http://127.0.0.1:8000/sql", data=s.encode(), method="POST", headers={
        "Authorization": "Basic " + base64.b64encode(("root:" + os.environ["SURREAL_ROOT_PASS"]).encode()).decode(),
        "surreal-ns": "kubo", "surreal-db": db, "Accept": "application/json"})
    return json.loads(urllib.request.urlopen(r, timeout=120).read())
q(f"DEFINE NAMESPACE IF NOT EXISTS kubo; USE NS kubo; DEFINE DATABASE IF NOT EXISTS {db};")
tables = sorted(q("INFO FOR DB;")[0]["result"]["tables"])
if tables:
    res = q(";".join(f"REMOVE TABLE {t};" for t in tables))
    bad = [x for x in res if x.get("status") != "OK"]
    assert not bad, bad[:2]
print(f"  [ok]    destino limpo ({len(tables)} tabelas removidas; usuários preservados)")
PY
cx "cd /opt/oute-surreal-db && set -a && . ./.env && set +a && SURREAL_ENDPOINT=http://127.0.0.1:8000 SURREAL_PASS=\"\$SURREAL_ROOT_PASS\" python3 scripts/import_dump.py ${DUMP} ${NS} ${TARGET_DB}" | sed 's/^/   /' \
  || die "import falhou. Para retomar o banco local: ${RESUME}"

step "Conferindo: contagem por tabela (origem x destino) e KNN"
Q="$(for t in ${TABLES}; do printf 'SELECT count() FROM %s GROUP ALL;' "${t}"; done)"
rx "lxc exec ${KUBO_LXC} -- docker exec -e Q='${Q}' ${SIDECAR} sh -c 'AUTH=\$(printf \"%s:%s\" \"\$SURREAL_USER\" \"\$SURREAL_PASS\" | base64 | tr -d \"\\n\"); wget -qO- --header=\"Authorization: Basic \$AUTH\" --header=\"surreal-ns: \$SURREAL_NS\" --header=\"surreal-db: \$SURREAL_DB\" --header=\"Accept: application/json\" --post-data=\"\$Q\" http://surrealdb:8000/sql'" </dev/null > "${WORK}/src.json"
rx "lxc exec ${CENTRAL} -- sh -c 'cd /opt/oute-surreal-db && set -a && . ./.env && set +a && Q=\"\$1\" TARGET_DB=${TARGET_DB} python3 -' _ '${Q}'" > "${WORK}/dst.json" <<'PY'
import base64, os, urllib.request
r = urllib.request.Request("http://127.0.0.1:8000/sql", data=os.environ["Q"].encode(), method="POST", headers={
    "Authorization": "Basic " + base64.b64encode(("root:" + os.environ["SURREAL_ROOT_PASS"]).encode()).decode(),
    "surreal-ns": "kubo", "surreal-db": os.environ["TARGET_DB"], "Accept": "application/json"})
print(urllib.request.urlopen(r, timeout=120).read().decode())
PY
python3 - "${TABLES}" "${WORK}/src.json" "${WORK}/dst.json" <<'PY' || die "contagem divergente. Para retomar o banco local: ${RESUME}"
import json, sys
tables = sys.argv[1].split(); src = json.load(open(sys.argv[2])); dst = json.load(open(sys.argv[3]))
def count(r):
    return "ERR" if r.get("status") != "OK" else (r["result"][0]["count"] if r["result"] else 0)
diff = [(t, count(a), count(b)) for t, a, b in zip(tables, src, dst) if count(a) != count(b)]
ts = sum(c for c in (count(a) for a in src) if isinstance(c, int)); td = sum(c for c in (count(b) for b in dst) if isinstance(c, int))
for t, x, y in diff[:10]: print(f"   DIVERGE {t}: origem={x} destino={y}")
print(f"  {'[ok]   ' if not diff else '[ERRO] '} tabelas={len(tables)} divergências={len(diff)} registros origem={ts} destino={td}")
sys.exit(1 if diff or len(src) != len(tables) or len(dst) != len(tables) else 0)
PY
central_py <<'PY' || die "KNN falhou no destino. Para retomar o banco local: ${RESUME}"
import base64, json, os, re, urllib.request
db = os.environ["TARGET_DB"]
def q(s):
    r = urllib.request.Request("http://127.0.0.1:8000/sql", data=s.encode(), method="POST", headers={
        "Authorization": "Basic " + base64.b64encode(("root:" + os.environ["SURREAL_ROOT_PASS"]).encode()).decode(),
        "surreal-ns": "kubo", "surreal-db": db, "Accept": "application/json"})
    return json.loads(urllib.request.urlopen(r, timeout=120).read())
import glob
dump = sorted(glob.glob("/root/migrate-*.surql"))[-1]
tested = 0
for line in open(dump):
    m = re.match(r"DEFINE INDEX (\S+) ON (\S+) FIELDS (\S+) HNSW", line)
    if not m:
        continue
    name, table, field = m.groups()
    rows = q(f"SELECT count() FROM {table} GROUP ALL;")[0]["result"]
    if not rows or not rows[0]["count"]:
        continue
    res = q(f"LET $v = (SELECT VALUE {field} FROM {table} LIMIT 1)[0]; SELECT id FROM {table} WHERE {field} <|3,40|> $v;")[-1]
    assert res["status"] == "OK" and res.get("result"), (name, res)
    print(f"  [ok]    KNN em {name} ({table}.{field}): {len(res['result'])} vizinhos")
    tested += 1
    break
if not tested:
    print("  [aviso] nenhum índice HNSW com dados para testar KNN")
PY

step "Concluído"
echo "  Dados de ${KUBO_LXC} copiados e conferidos em ${NS}/${TARGET_DB} (dump apagado do central)."
if [ "${STOP_WRITERS}" -eq 1 ]; then
  echo "  scheduler e api do ${KUBO_LXC} seguem PARADOS. Próximos passos:"
  echo "    1. config do .env:    (no repo do kubo) ./scripts/ops/kubo-${ENVNAME}-use-central.sh"
  echo "    2. subir no central:  ./ops/start_kubo_on_central.sh ${ENVNAME}"
  echo "  Para desistir e voltar ao banco local:  ${RESUME}"
fi
