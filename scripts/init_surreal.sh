#!/usr/bin/env bash
#
# init_surreal.sh
# Para cada projeto:ambientes em SURREAL_PROJECTS cria namespace, databases e três usuários por database:
#   app_<db>  ROLES OWNER   (a aplicação: DDL/migrations + dados)
#   rw_<db>   ROLES EDITOR  (lê/escreve dados e schema, mas NÃO gerencia usuários/acessos: caminho de escrita da UI)
#   ro_<db>   ROLES VIEWER  (backup, consultas, leitura)
# Idempotente: usuários existentes NÃO são tocados. Para gerar senhas novas use --rotate [projeto...].
# Senhas são impressas UMA vez; guarde no cofre. Nada é salvo em disco.
#
# Uso (no LXC, na raiz do repo, com .env preenchido):
#   ./scripts/init_surreal.sh                 # cria o que falta
#   ./scripts/init_surreal.sh --rotate kubo   # recria senhas só do projeto kubo
#   ./scripts/init_surreal.sh --rotate        # recria senhas de todos (derruba apps!)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../.env}"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

CONTAINER="${SURREAL_CONTAINER_NAME:-oute-surreal-db}"
ROOT_USER="${SURREAL_ROOT_USER:-root}"
: "${SURREAL_ROOT_PASS:?SURREAL_ROOT_PASS não definido}"
: "${SURREAL_PROJECTS:?SURREAL_PROJECTS não definido}"

ROTATE=0
ROTATE_ONLY=""
if [ "${1:-}" = "--rotate" ]; then
  ROTATE=1
  shift
  ROTATE_ONLY="$*"
fi

sql() {
  docker exec -i "${CONTAINER}" /surreal sql \
    --endpoint http://127.0.0.1:8000 \
    --user "${ROOT_USER}" --pass "${SURREAL_ROOT_PASS}" \
    --hide-welcome "$@"
}

user_exists() { # ns db user
  sql --ns "$1" --db "$2" <<<"INFO FOR DB;" 2>/dev/null | grep -q "\b$3\b"
}

should_rotate() { # project
  [ "${ROTATE}" -eq 1 ] || return 1
  [ -z "${ROTATE_ONLY}" ] && return 0
  for p in ${ROTATE_ONLY}; do [ "$p" = "$1" ] && return 0; done
  return 1
}

define_user() { # ns db user role project
  if user_exists "$1" "$2" "$3" && ! should_rotate "$5"; then
    echo "ns=$1 db=$2 user=$3 (já existe, mantido)"
    return
  fi
  local pass
  pass="$(openssl rand -base64 32 | tr -d '/+=\n')"
  sql --ns "$1" --db "$2" <<<"DEFINE USER OVERWRITE $3 ON DATABASE PASSWORD '${pass}' ROLES $4;" >/dev/null
  echo "ns=$1 db=$2 user=$3 role=$4 pass=${pass}"
}

for entry in ${SURREAL_PROJECTS}; do
  project="${entry%%:*}"
  dbs="${entry#*:}"
  [ "${dbs}" != "${entry}" ] || { echo "ERRO: '${entry}' sem ambientes (use projeto:prd,test)" >&2; exit 1; }
  ns="${project//-/_}"
  for db in ${dbs//,/ }; do
    sql --ns "${ns}" --db "${db}" >/dev/null <<SQL
DEFINE NAMESPACE IF NOT EXISTS ${ns};
DEFINE DATABASE IF NOT EXISTS ${db};
SQL
    define_user "${ns}" "${db}" "app_${db}" OWNER "${project}"
    define_user "${ns}" "${db}" "rw_${db}" EDITOR "${project}"
    define_user "${ns}" "${db}" "ro_${db}" VIEWER "${project}"
  done
done

echo >&2
echo ">> Guarde as senhas acima no cofre. Elas não são salvas em disco." >&2
