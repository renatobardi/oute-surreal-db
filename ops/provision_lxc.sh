#!/usr/bin/env bash
#
# provision_lxc.sh — cria/atualiza o LXC oute-surreal-db no oute-server e sobe o SurrealDB.
# Roda no Mac; tudo que precisa do servidor vai via ssh. Não usa sudo.
#
#   ./ops/provision_lxc.sh --check   # só pré-checagens (não altera nada)
#   ./ops/provision_lxc.sh           # cria/atualiza e verifica
#
# Idempotente: reexecutar reaplica o firewall, atualiza o repo no LXC, sobe o compose e roda o init
# (usuários existentes são mantidos; o .env e a senha root existentes não são tocados).
# Envia para o LXC o HEAD COMMITADO do repo (git archive): commite antes de rodar.
#
# Isolamento: firewall nft DENTRO do LXC (tabela própria; só os clientes listados chegam na 8000).
# Necessário porque containers Docker do HOST alcançam IPs de LXC (medido em 2026-10-18); eles
# chegam mascarados como o IP da lxdbr0 (10.173.117.1), que não está na lista. (ACL do LXD em NIC
# de bridge não existe no LXD 5.21.)
# Segredos: a senha root é gerada dentro do LXC (.env, 600) e as senhas dos usuários vêm do
# init. Ambas são mostradas UMA vez no terminal no final; guarde no cofre. Nada vai pra disco aqui.

set -euo pipefail

HOST="${OUTE_HOST:-oute-server}"
NAME="${LXC_NAME:-oute-surreal-db}"
IP="${LXC_IP:-10.173.117.50}"
LXC_CPU="${LXC_CPU:-2}"
LXC_MEM="${LXC_MEM:-3GiB}"
# Clientes autorizados (IPs dos LXCs): kubo-prd, kubo-test, obo-prd. Novo projeto = novo IP aqui
# (ou SURREAL_CLIENT_IPS="..." na linha de comando) e reexecutar. Ver docs/OPERATIONS.md.
CLIENTS="${SURREAL_CLIENT_IPS:-10.173.117.21 10.173.117.18 10.173.117.30}"
POS_LXC="${POS_LXC:-kubo-test}"     # deve alcançar
NEG_LXC="${NEG_LXC:-vaultwarden}"   # não pode alcançar (fora da lista)
PORT=8000

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
r() { ssh "${SSH_OPTS[@]}" "${HOST}" "$@"; }                 # comando no servidor
x() { r "lxc exec ${NAME} -- bash -s"; }                     # script (stdin) dentro do LXC

ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [AVISO] %s\n' "$*"; }
die()  { printf '  [ERRO] %s\n' "$*" >&2; exit 1; }

echo ">> Pré-checagens"
r true 2>/dev/null || die "sem ssh para '${HOST}'"
ok "ssh ${HOST}"
for c in ${CLIENTS} ; do r "lxc list -c 4 -f csv | grep -q '^${c} '" || warn "cliente ${c} não encontrado em nenhum LXC"; done
EXISTS=0; r "lxc info ${NAME} >/dev/null 2>&1" && EXISTS=1
if [ "${EXISTS}" -eq 0 ]; then
  r "lxc list -c n4 -f csv | grep '${IP} ' " >/dev/null 2>&1 && die "IP ${IP} já em uso por outro LXC"
  ok "IP ${IP} livre; LXC ${NAME} ainda não existe (será criado)"
else
  ok "LXC ${NAME} já existe (será atualizado)"
fi
for l in "${POS_LXC}" "${NEG_LXC}"; do r "lxc info ${l} >/dev/null 2>&1" || die "LXC de teste '${l}' não existe"; done
ok "LXCs de teste: ${POS_LXC} (positivo), ${NEG_LXC} (negativo)"
AVAIL="$(r "free -m | awk '/^Mem:/{print \$7}'")"
[ "${AVAIL}" -gt 3500 ] && ok "RAM disponível no host: ${AVAIL} MiB" || warn "RAM disponível baixa (${AVAIL} MiB) para ${LXC_MEM}"
[ -z "$(git -C "${REPO_DIR}" status --porcelain)" ] || warn "repo com mudanças não commitadas: só o HEAD será enviado"
[ "${CHECK_ONLY}" -eq 1 ] && { echo ">> --check concluído; nada foi alterado."; exit 0; }

echo ">> LXC ${NAME}"
if [ "${EXISTS}" -eq 0 ]; then
  r "lxc init ubuntu:24.04 ${NAME} -c security.nesting=true -c boot.autostart=true -c limits.cpu=${LXC_CPU} -c limits.memory=${LXC_MEM} -c snapshots.expiry=7d"
  ok "LXC criado"
fi
r "lxc config set ${NAME} security.nesting=true boot.autostart=true limits.cpu=${LXC_CPU} limits.memory=${LXC_MEM} snapshots.expiry=7d"
CUR_IP="$(r "lxc config device get ${NAME} eth0 ipv4.address 2>/dev/null || true")"
if [ "${CUR_IP}" != "${IP}" ]; then
  r "lxc config device override ${NAME} eth0 ipv4.address=${IP} 2>/dev/null || lxc config device set ${NAME} eth0 ipv4.address=${IP}"
fi
ok "IP fixo ${IP}"
r "lxc info ${NAME} | grep -q '^Status: RUNNING'" || { r "lxc start ${NAME}"; ok "LXC iniciado"; }

echo ">> Aguardando boot/rede do LXC"
r "lxc exec ${NAME} -- cloud-init status --wait >/dev/null 2>&1 || true"
x <<'EOS'
for i in $(seq 1 30); do getent hosts archive.ubuntu.com >/dev/null 2>&1 && exit 0; sleep 2; done
echo "sem DNS/rede no LXC" >&2; exit 1
EOS
ok "rede do LXC ok"

echo ">> Provisionando Docker no LXC (padrão da casa: docker.io + compose v2, dns 1.1.1.1)"
x <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! command -v docker >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq docker.io docker-compose-v2 curl openssl >/dev/null
fi
mkdir -p /etc/docker
[ -f /etc/docker/daemon.json ] || echo '{"dns":["1.1.1.1","1.0.0.1"]}' > /etc/docker/daemon.json
systemctl enable --now docker >/dev/null 2>&1
mkdir -p /opt/oute-surreal-db /srv/oute-surreal-db/data
chown 10001:10001 /srv/oute-surreal-db/data
docker --version
EOS

echo ">> Firewall no LXC (nft): só ${CLIENTS} -> :${PORT}"
CLIENTS_CSV="$(echo "${CLIENTS}" | sed 's/ /, /g')"
x <<EOS
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
command -v nft >/dev/null 2>&1 || apt-get install -y -qq nftables >/dev/null
cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
# Gerado por ops/provision_lxc.sh. Tabela própria: não mexe nas regras do Docker.
NFT
cat >> /etc/nftables.conf <<NFT
add table inet oute_sdb
delete table inet oute_sdb
table inet oute_sdb {
  chain sdb_forward {
    type filter hook forward priority -10; policy accept;
    iifname "eth0" tcp dport ${PORT} ip saddr != { ${CLIENTS_CSV} } counter drop
  }
}
NFT
nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl enable nftables >/dev/null 2>&1
nft list table inet oute_sdb
EOS
ok "firewall aplicado e persistido (/etc/nftables.conf)"

echo ">> Enviando o repo (HEAD commitado)"
git -C "${REPO_DIR}" archive --format=tar HEAD | r "lxc exec ${NAME} -- tar -x -C /opt/oute-surreal-db"
ok "repo em /opt/oute-surreal-db"

echo ">> .env e compose"
ROOT_PASS_NEW="$(x <<'EOS'
set -euo pipefail
cd /opt/oute-surreal-db
if [ ! -f .env ]; then
  cp .env.example .env
  pass="$(openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-40)"
  sed -i "s|^SURREAL_ROOT_PASS=.*|SURREAL_ROOT_PASS=${pass}|" .env
  chmod 600 .env
  echo "${pass}"
fi
EOS
)"
[ -n "${ROOT_PASS_NEW}" ] && ok ".env criado (600) com senha root nova" || ok ".env já existia (mantido)"
x <<'EOS'
set -euo pipefail
cd /opt/oute-surreal-db
docker compose --env-file .env -f docker/docker-compose.yml up -d >/dev/null
for i in $(seq 1 45); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' oute-surreal-db 2>/dev/null)" = healthy ] && { echo "healthy"; exit 0; }
  sleep 2
done
docker logs --tail 30 oute-surreal-db >&2; echo "não ficou healthy" >&2; exit 1
EOS
ok "container healthy"

echo ">> Init (namespaces/databases/usuários) — senhas abaixo, UMA vez:"
echo "------------------------------------------------------------------"
x <<'EOS' 2>&1 | grep -v onnxruntime
cd /opt/oute-surreal-db && ./scripts/init_surreal.sh
EOS
[ -n "${ROOT_PASS_NEW}" ] && echo "root (somente ops) pass=${ROOT_PASS_NEW}"
echo "------------------------------------------------------------------"

echo ">> Verificação de isolamento"
FAIL=0
reach() { # <lxc> -> imprime ALCANCA|BLOQUEADO
  r "lxc exec $1 -- timeout 5 bash -c 'exec 3<>/dev/tcp/${IP}/${PORT} && printf \"GET /health HTTP/1.0\r\n\r\n\" >&3 && head -1 <&3' 2>/dev/null | grep -q 200" && echo ALCANCA || echo BLOQUEADO
}
res="$(reach "${POS_LXC}")"; [ "${res}" = ALCANCA ] && ok "${POS_LXC} -> ${IP}:${PORT}: alcança (esperado)" || { warn "${POS_LXC} NÃO alcança (esperado alcançar)"; FAIL=1; }
res="$(reach "${NEG_LXC}")"; [ "${res}" = BLOQUEADO ] && ok "${NEG_LXC} (fora da lista): bloqueado (esperado)" || { warn "${NEG_LXC} ALCANÇA o banco (esperado bloqueio)"; FAIL=1; }
for net in bridge oute-agent_oute; do
  res="$(r "docker run --rm --network ${net} alpine sh -c 'wget -T 4 -q -O /dev/null http://${IP}:${PORT}/health && echo ALCANCA || echo BLOQUEADO' 2>/dev/null | tail -1")"
  [ "${res}" = BLOQUEADO ] && ok "container Docker do host (rede ${net}): bloqueado (esperado)" || { warn "container Docker do host (rede ${net}) ALCANÇA o banco"; FAIL=1; }
done

echo
if [ "${FAIL}" -eq 0 ]; then
  echo ">> Provisionamento concluído: ${NAME} em ${IP}:${PORT}, isolamento verificado."
  echo ">> Próximo: guardar as senhas no cofre; snapshot manual: ssh ${HOST} lxc snapshot ${NAME} <nome>"
else
  echo ">> F2 aplicada, MAS a verificação de isolamento falhou (ver AVISO acima). Não migre dados antes de resolver." >&2
  echo ">> Se só o Docker do host alcança: o firewall do LXC não pegou o tráfego do host; a alternativa" >&2
  echo ">> é regra em DOCKER-USER no host (precisa sudo) — me avise antes de seguir." >&2
  exit 2
fi
