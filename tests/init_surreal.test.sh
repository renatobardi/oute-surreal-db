#!/usr/bin/env bash
#
# Teste de integração do scripts/init_surreal.sh contra um SurrealDB v3.3.0 real (Docker local, surrealkv).
# Uso: ./tests/init_surreal.test.sh      (exige docker; não toca em nada fora de um container/dir temporário)
# Não imprime senhas.

set -u   # sem pipefail: `grep -q` fecha o pipe cedo e derrubaria o status do pipeline
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="surrealdb/surrealdb:v3.3.0"
NAME="sdb-init-test-$$"
TMP="$(mktemp -d)"
ROOT_PASS="root-$(openssl rand -hex 8)"
FAILS=0; PASSES=0

cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1; rm -rf "${TMP}"; }
trap cleanup EXIT

pass() { PASSES=$((PASSES+1)); printf '  ok    %s\n' "$*"; }
fail() { FAILS=$((FAILS+1)); printf '  FALHA %s\n' "$*"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

mkdir -p "${TMP}/data" && chmod 777 "${TMP}/data"
docker run -d --name "${NAME}" -e SURREAL_USER=root -e SURREAL_PASS="${ROOT_PASS}" \
  -v "${TMP}/data:/data" "${IMAGE}" start --no-banner --bind 0.0.0.0:8000 surrealkv:///data/db >/dev/null
for _ in $(seq 1 30); do docker exec "${NAME}" /surreal is-ready --endpoint http://127.0.0.1:8000 >/dev/null 2>&1 && break; sleep 1; done

cat > "${TMP}/.env" <<ENV
SURREAL_CONTAINER_NAME=${NAME}
SURREAL_ROOT_USER=root
SURREAL_ROOT_PASS=${ROOT_PASS}
SURREAL_PROJECTS="kubo:prd,test obo:prd"
ENV
export ENV_FILE="${TMP}/.env"

# sql <user> <pass> <ns> <db> <statement>  -> usuário de database
dbsql() {
  docker exec -i "${NAME}" /surreal sql --endpoint http://127.0.0.1:8000 --hide-welcome \
    --user "$1" --pass "$2" --auth-level database --ns "$3" --db "$4" <<<"$5" 2>&1 | grep -v onnxruntime
}
rootsql() {
  docker exec -i "${NAME}" /surreal sql --endpoint http://127.0.0.1:8000 --hide-welcome \
    --user root --pass "${ROOT_PASS}" --ns "$1" --db "$2" <<<"$3" 2>&1 | grep -v onnxruntime
}
# pw <saída do init> <ns> <db> <user>
pw() { echo "$1" | grep "^ns=$2 db=$3 user=$4 " | grep -o 'pass=.*' | sed 's/^pass=//'; }

echo "== 1ª execução =="
OUT1="$("${ROOT_DIR}/scripts/init_surreal.sh" 2>/dev/null)"
for u in app_prd rw_prd ro_prd; do check "kubo/prd tem usuário ${u}" "rootsql kubo prd 'INFO FOR DB;' | grep -q '${u}'"; done
for u in app_test rw_test ro_test; do check "kubo/test tem usuário ${u}" "rootsql kubo test 'INFO FOR DB;' | grep -q '${u}'"; done
for u in app_prd rw_prd ro_prd; do check "obo/prd tem usuário ${u}" "rootsql obo prd 'INFO FOR DB;' | grep -q '${u}'"; done
check "obo NÃO tem database test" "! rootsql obo prd 'INFO FOR NS;' | grep -q 'test'"
check "nenhuma database 'main' sobrando" "! rootsql kubo prd 'INFO FOR NS;' | grep -q 'main'"

APP="$(pw "${OUT1}" kubo prd app_prd)"; RW="$(pw "${OUT1}" kubo prd rw_prd)"; RO="$(pw "${OUT1}" kubo prd ro_prd)"
check "init imprimiu senha de app_prd, rw_prd e ro_prd" "[ -n '${APP}' ] && [ -n '${RW}' ] && [ -n '${RO}' ]"

echo "== papéis =="
check "OWNER (app) cria tabela (DDL)"        "dbsql app_prd '${APP}' kubo prd 'DEFINE TABLE t SCHEMALESS;' | grep -qvi 'permission'"
check "OWNER escreve dados"                  "dbsql app_prd '${APP}' kubo prd 'CREATE t:1 SET a=1;' | grep -q 'a: 1'"
check "EDITOR (rw) escreve dados"            "dbsql rw_prd '${RW}' kubo prd 'CREATE t:2 SET a=2;' | grep -q 'a: 2'"
check "OWNER (app) gerencia usuários"         "dbsql app_prd '${APP}' kubo prd \"DEFINE USER made_by_owner ON DATABASE PASSWORD 'x' ROLES VIEWER;\" >/dev/null; rootsql kubo prd 'INFO FOR DB;' | grep -q made_by_owner"
check "EDITOR (rw) NÃO gerencia usuários"    "dbsql rw_prd '${RW}' kubo prd \"DEFINE USER sneaky ON DATABASE PASSWORD 'x' ROLES OWNER;\" >/dev/null; ! rootsql kubo prd 'INFO FOR DB;' | grep -q sneaky"
check "VIEWER (ro) lê"                       "dbsql ro_prd '${RO}' kubo prd 'SELECT * FROM t;' | grep -q 'a: 1'"
check "VIEWER (ro) NÃO escreve"              "dbsql ro_prd '${RO}' kubo prd 'CREATE t:3 SET a=3;' >/dev/null; ! rootsql kubo prd 'SELECT * FROM t:3;' | grep -q 'a: 3'"
check "usuário do kubo NÃO entra no obo"     "dbsql app_prd '${APP}' obo prd 'SELECT * FROM t;' | grep -qi 'authentication'"
check "usuário de kubo/prd NÃO entra em kubo/test" "dbsql app_prd '${APP}' kubo test 'SELECT * FROM t;' | grep -qi 'authentication'"

echo "== idempotência =="
OUT2="$("${ROOT_DIR}/scripts/init_surreal.sh" 2>/dev/null)"
check "2ª execução mantém todos (sem senha nova)" "! echo '${OUT2}' | grep -q 'pass=' && [ \"\$(echo '${OUT2}' | grep -c 'mantido')\" = 9 ]"
check "senha antiga de rw_prd continua válida"   "dbsql rw_prd '${RW}' kubo prd 'SELECT * FROM t;' | grep -q 'a: 1'"

echo "== --rotate de um projeto =="
OUT3="$("${ROOT_DIR}/scripts/init_surreal.sh" --rotate kubo 2>/dev/null)"
RW2="$(pw "${OUT3}" kubo prd rw_prd)"
check "rotate gera senha nova para rw_prd de kubo" "[ -n '${RW2}' ] && [ '${RW2}' != '${RW}' ]"
check "senha antiga de rw_prd deixa de valer"      "dbsql rw_prd '${RW}' kubo prd 'SELECT * FROM t;' | grep -qi 'authentication'"
check "senha nova de rw_prd vale"                  "dbsql rw_prd '${RW2}' kubo prd 'SELECT * FROM t;' | grep -q 'a: 1'"
check "rotate de kubo não toca o obo"              "echo '${OUT3}' | grep '^ns=obo' | grep -q 'mantido'"

echo
echo "${PASSES} ok, ${FAILS} falha(s)"
[ "${FAILS}" -eq 0 ]
