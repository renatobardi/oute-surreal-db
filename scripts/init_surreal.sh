#!/usr/bin/env bash
#
# init_surreal.sh
# Cria um namespace por projeto, databases dev/prod e um usuário OWNER (app_dev / app_prod) por database.
# Idempotente: usuários existentes NÃO são tocados. Para gerar senhas novas use --rotate [projeto...].
# Senhas são impressas UMA vez; guarde no cofre. Nada é salvo em disco.
#
# Uso (no servidor, na raiz do repo, com .env preenchido):
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

for project in ${SURREAL_PROJECTS}; do
  ns="${project//-/_}"
  for db in dev prod; do
    sql <<SQL >/dev/null
DEFINE NAMESPACE IF NOT EXISTS ${ns};
USE NS ${ns};
DEFINE DATABASE IF NOT EXISTS ${db};
SQL
    user="app_${db}"
    if user_exists "${ns}" "${db}" "${user}" && ! should_rotate "${project}"; then
      echo "ns=${ns} db=${db} user=${user} (já existe, mantido)"
      continue
    fi
    pass="$(openssl rand -base64 32 | tr -d '/+=\n')"
    sql --ns "${ns}" --db "${db}" <<<"DEFINE USER OVERWRITE ${user} ON DATABASE PASSWORD '${pass}' ROLES OWNER;" >/dev/null
    echo "ns=${ns} db=${db} user=${user} pass=${pass}"
  done
done

echo >&2
echo ">> Guarde as senhas acima no cofre. Elas não são salvas em disco." >&2
