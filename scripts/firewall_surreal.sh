#!/usr/bin/env bash
#
# firewall_surreal.sh
# Isola o oute-surreal-db: só a rede LXD (SURREAL_ALLOWED_CIDR) chega na porta publicada,
# e o container não inicia conexão alguma para fora. Bloqueia, em especial, os demais
# containers Docker do host (que alcançam 10.173.117.1 via roteamento).
#
# Idempotente. Precisa de root. Persistido pelo systemd/oute-surreal-firewall.service
# (as regras em DOCKER-USER somem no reboot).
#
# Uso: sudo ./scripts/firewall_surreal.sh [--remove]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../.env}"
# shellcheck disable=SC1090
[ -f "${ENV_FILE}" ] && source "${ENV_FILE}"

BRIDGE="${SURREAL_BRIDGE:-br-oute-sdb}"
ALLOWED="${SURREAL_ALLOWED_CIDR:-10.173.117.0/24}"

[ "$(id -u)" -eq 0 ] || { echo "ERRO: rode como root (sudo)." >&2; exit 1; }
iptables -L DOCKER-USER -n >/dev/null 2>&1 || { echo "ERRO: chain DOCKER-USER ausente; Docker está rodando?" >&2; exit 1; }

# Regras (ordem importa; são inseridas no topo em ordem inversa).
RULES=(
  "-o ${BRIDGE} ! -s ${ALLOWED} -j DROP"
  "-i ${BRIDGE} -j DROP"
  "-i ${BRIDGE} -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN"
)

remove() {
  for r in "${RULES[@]}"; do
    # shellcheck disable=SC2086
    while iptables -C DOCKER-USER $r 2>/dev/null; do iptables -D DOCKER-USER $r; done
  done
}

if [ "${1:-}" = "--remove" ]; then
  remove
  echo "Regras removidas."
  exit 0
fi

remove
for r in "${RULES[@]}"; do
  # shellcheck disable=SC2086
  iptables -I DOCKER-USER 1 $r
done

echo "DOCKER-USER (bridge ${BRIDGE}, permitido ${ALLOWED}):"
iptables -S DOCKER-USER | grep -- "${BRIDGE}"
