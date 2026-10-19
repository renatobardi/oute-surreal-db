#!/usr/bin/env bash
#
# rotate_and_show_credentials.sh — mostra as credenciais do oute-surreal-db NO SEU TERMINAL (uma vez).
# Gera senhas NOVAS para todos os usuários app_/ro_ (init --rotate) e mostra a senha root do .env.
# Seguro enquanto nenhum app usa o banco (pré-migração). Depois disso, rotacione só o projeto
# necessário: ./scripts/init_surreal.sh --rotate <projeto> dentro do LXC.
# Nada é gravado em disco; guarde no cofre (Vaultwarden).
#
#   ./ops/rotate_and_show_credentials.sh

set -euo pipefail
HOST="${OUTE_HOST:-oute-server}"
NAME="${LXC_NAME:-oute-surreal-db}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

echo ">> Gerando senhas novas (init --rotate) em ${NAME}..." >&2
echo "------------------------------------------------------------------"
ssh "${SSH_OPTS[@]}" "${HOST}" "lxc exec ${NAME} -- bash -c 'cd /opt/oute-surreal-db && ./scripts/init_surreal.sh --rotate'" </dev/null 2>&1 | grep -v onnxruntime
echo -n "root (somente ops) pass="
ssh "${SSH_OPTS[@]}" "${HOST}" "lxc exec ${NAME} -- bash -c 'grep ^SURREAL_ROOT_PASS= /opt/oute-surreal-db/.env | cut -d= -f2-'" </dev/null
echo "------------------------------------------------------------------"
echo ">> Guarde no cofre: oute-surreal-db/root e oute-surreal-db/<ns>/<db>/<usuário>." >&2
echo ">> Endpoint para os apps: ws://10.173.117.50:8000/rpc (só kubo-prd, kubo-test, obo-prd alcançam)." >&2
