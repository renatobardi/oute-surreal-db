#!/usr/bin/env bash
#
# backup_surreal.sh
# Exporta cada namespace/database e mantém apenas os 2 dumps mais recentes de cada um.
# Executado semanalmente pelo systemd timer (systemd/oute-surreal-backup.timer).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../.env}"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

CONTAINER="${SURREAL_CONTAINER_NAME:-oute-surreal-db}"
ROOT_USER="${SURREAL_ROOT_USER:-root}"
BACKUP_DIR="${SURREAL_BACKUP_DIR:-/mnt/lxd/oute-data/backups/surrealdb}"
KEEP="${KEEP:-2}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "${BACKUP_DIR}"

for project in ${SURREAL_PROJECTS}; do
  ns="${project//-/_}"
  for db in dev prod; do
    out="${BACKUP_DIR}/${ns}_${db}_${TIMESTAMP}.surql"
    if docker exec "${CONTAINER}" /surreal export \
        --endpoint http://localhost:8000 \
        --user "${ROOT_USER}" --pass "${SURREAL_ROOT_PASS}" \
        --ns "${ns}" --db "${db}" - > "${out}.tmp"; then
      mv "${out}.tmp" "${out}"
      echo "OK: ${out}"
    else
      rm -f "${out}.tmp"
      echo "AVISO: falha ao exportar ${ns}/${db}" >&2
      continue
    fi

    # Retenção: mantém somente os KEEP dumps mais recentes deste ns/db.
    # shellcheck disable=SC2012
    ls -1t "${BACKUP_DIR}/${ns}_${db}_"*.surql 2>/dev/null | tail -n +"$((KEEP + 1))" | xargs -r rm -f --
  done
done
