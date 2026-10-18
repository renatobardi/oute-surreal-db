#!/usr/bin/env bash
#
# init_surreal.sh
# Cria um namespace por projeto, databases dev/prod e um usuário (OWNER) por database.
# Idempotente quanto às estruturas; as senhas dos usuários são geradas a cada execução
# e impressas UMA vez no terminal para você guardar no VaultGarden.
#
# Uso (no servidor, na raiz do repo, com .env preenchido):
#   ./scripts/init_surreal.sh

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

sql() {
  docker exec -i "${CONTAINER}" /surreal sql \
    --endpoint http://localhost:8000 \
    --user "${ROOT_USER}" --pass "${SURREAL_ROOT_PASS}" \
    --hide-welcome
}

for project in ${SURREAL_PROJECTS}; do
  ns="${project//-/_}"
  for db in dev prod; do
    pass="$(openssl rand -base64 32 | tr -d '/+=\n')"
    sql <<SQL >/dev/null
DEFINE NAMESPACE IF NOT EXISTS ${ns};
USE NS ${ns};
DEFINE DATABASE IF NOT EXISTS ${db};
USE NS ${ns} DB ${db};
DEFINE USER OVERWRITE app_${db} ON DATABASE PASSWORD '${pass}' ROLES OWNER;
SQL
    echo "ns=${ns} db=${db} user=app_${db} pass=${pass}"
  done
done

echo >&2
echo ">> Guarde as senhas acima no VaultGarden. Elas não são salvas em disco." >&2
