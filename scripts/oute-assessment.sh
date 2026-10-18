#!/usr/bin/env bash
#
# oute-assessment.sh
# Assessment geral do VPS (oute-server), executado a partir do Mac via SSH.
# Somente leitura: nenhuma alteração é feita no servidor.
#
# Uso:
#   ./oute-surreal-db/scripts/oute-assessment.sh
#   OUTE_HOST=meu-host DATA_DIR=/mnt/lxd/oute-surreal-db DB_PORT=8000 ./oute-surreal-db/scripts/oute-assessment.sh
#
# Variáveis opcionais:
#   OUTE_HOST   Host SSH (default: oute-server)
#   DATA_DIR    Diretório de dados do SurrealDB (default: /mnt/lxd/oute-surreal-db)
#   DB_PORT     Porta a validar (default: 8000)
#   LXD_BRIDGE  Bridge LXD (default: lxdbr0)
#   REPORT_DIR  Diretório local dos relatórios (default: <repo>/reports)

set -euo pipefail

OUTE_HOST="${OUTE_HOST:-oute-server}"
DATA_DIR="${DATA_DIR:-/mnt/lxd/oute-surreal-db}"
DB_PORT="${DB_PORT:-8000}"
LXD_BRIDGE="${LXD_BRIDGE:-lxdbr0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${REPORT_DIR:-${SCRIPT_DIR}/../reports}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOCAL_REPORT="${REPORT_DIR}/oute_assessment_${TIMESTAMP}.txt"

mkdir -p "${REPORT_DIR}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

echo ">> Conectando em ${OUTE_HOST}..." >&2
if ! ssh "${SSH_OPTS[@]}" "${OUTE_HOST}" "true" 2>/dev/null; then
  echo "ERRO: não foi possível conectar via SSH em '${OUTE_HOST}'." >&2
  echo "Verifique ~/.ssh/config, a chave SSH e a conectividade." >&2
  exit 1
fi

# Script executado no servidor remoto (heredoc com aspas: nada é expandido localmente).
read -r -d '' REMOTE_SCRIPT <<'REMOTE_EOF' || true
set -u

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  SUDO="sudo -n"
fi

section() {
  printf '\n==================== %s ====================\n' "$1"
}

# Executa um comando exibindo-o antes; nunca aborta o assessment.
run() {
  printf '\n$ %s\n' "$*"
  "$@" </dev/null 2>&1 || printf '[aviso] comando falhou ou indisponível (exit %s)\n' "$?"
}

# Executa uma string de shell (para pipes) com o mesmo comportamento.
runsh() {
  printf '\n$ %s\n' "$1"
  bash -c "$1" </dev/null 2>&1 || printf '[aviso] comando falhou ou indisponível (exit %s)\n' "$?"
}

have() { command -v "$1" >/dev/null 2>&1; }

echo "Oute assessment - $(date -Is)"
echo "Host: $(hostname) | Usuário: $(id -un) | sudo sem senha: $([ -n "$SUDO" ] && echo sim || echo não)"

section "SISTEMA"
runsh "cat /etc/os-release | head -n 5"
run uname -a
run uptime

section "CPU E MEMÓRIA"
runsh "nproc"
runsh "lscpu | grep -E 'Model name|^CPU\(s\)|Architecture'"
run free -h

section "DISCOS E PARTIÇÕES"
run lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
run df -hT -x tmpfs -x devtmpfs -x squashfs
run df -i /

section "DIRETÓRIO DE DADOS (${DATA_DIR})"
if [ -d "${DATA_DIR}" ]; then
  echo "Existe: sim"
  run ls -ld "${DATA_DIR}"
  run df -hT "${DATA_DIR}"
  runsh "${SUDO} du -sh '${DATA_DIR}' 2>/dev/null"
else
  echo "Existe: não"
  parent="$(dirname "${DATA_DIR}")"
  echo "Diretório pai: ${parent}"
  run df -hT "${parent}"
fi

section "REDE"
run ip -br addr
runsh "ip route | head -n 10"
echo
echo "IP da bridge ${LXD_BRIDGE}:"
runsh "ip -4 -br addr show ${LXD_BRIDGE}"

section "PORTAS EM ESCUTA"
if have ss; then
  runsh "${SUDO} ss -ltnp"
else
  runsh "${SUDO} netstat -ltnp"
fi
echo
if ss -ltnH "sport = :${DB_PORT}" 2>/dev/null | grep -q .; then
  echo "Porta ${DB_PORT}: EM USO"
  runsh "${SUDO} ss -ltnp 'sport = :${DB_PORT}'"
else
  echo "Porta ${DB_PORT}: LIVRE"
fi

section "DOCKER"
if have docker; then
  DOCKER="docker"
  docker info >/dev/null 2>&1 || DOCKER="${SUDO} docker"
  runsh "${DOCKER} --version"
  runsh "${DOCKER} compose version"
  runsh "${DOCKER} ps -a --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
  runsh "${DOCKER} volume ls"
  runsh "${DOCKER} network ls"

  section "CONTAINER SURREALDB"
  found=0
  for name in oute-surreal-db oute-surrealdb; do
    if ${DOCKER} inspect "$name" >/dev/null 2>&1; then
      found=1
      echo "Container encontrado: $name"
      runsh "${DOCKER} inspect '$name' --format 'Imagem: {{.Config.Image}}
Estado: {{.State.Status}} (restarts: {{.RestartCount}})
Restart policy: {{.HostConfig.RestartPolicy.Name}}
Mounts: {{range .Mounts}}{{.Source}}->{{.Destination}} ({{.Type}}) {{end}}
Portas: {{json .NetworkSettings.Ports}}
Cmd: {{json .Config.Cmd}}'"
      echo
      echo "--- Redes (aliases e IPs) ---"
      runsh "${DOCKER} inspect '$name' --format '{{json .NetworkSettings.Networks}}'"
      echo
      echo "--- Labels (projeto compose / diretório de origem) ---"
      runsh "${DOCKER} inspect '$name' --format '{{json .Config.Labels}}'"
      echo
      echo "--- Variáveis de ambiente (somente nomes, sem valores) ---"
      runsh "${DOCKER} inspect '$name' --format '{{range .Config.Env}}{{println .}}{{end}}' | cut -d= -f1"
      echo
      echo "--- Healthcheck ---"
      runsh "${DOCKER} inspect '$name' --format '{{json .Config.Healthcheck}}'"
      runsh "${DOCKER} logs --tail 20 '$name'"
    fi
  done
  [ "$found" -eq 0 ] && echo "Nenhum container oute-surreal-db / oute-surrealdb encontrado."
else
  echo "Docker não instalado."
fi

section "LXC / LXD"
if have lxc; then
  LXC="lxc"
  lxc list >/dev/null 2>&1 || LXC="${SUDO} lxc"
  runsh "${LXC} list"
  runsh "${LXC} network list"
  runsh "${LXC} network show ${LXD_BRIDGE}"
  runsh "${LXC} storage list"
else
  echo "lxc não instalado."
fi

section "FIREWALL"
if have ufw; then
  runsh "${SUDO} ufw status verbose"
fi
if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
  echo "Sem root/sudo sem senha: regras nft/iptables não inspecionadas."
else
  if have nft; then
    runsh "${SUDO} nft list ruleset | head -n 80"
  fi
  if have iptables; then
    runsh "${SUDO} iptables -S | head -n 80"
  fi
fi

section "CRON E TIMERS"
runsh "crontab -l"
runsh "${SUDO} ls -la /etc/cron.d /etc/cron.weekly"
runsh "systemctl list-timers --no-pager | head -n 15"

section "SERVIÇOS"
runsh "systemctl --failed --no-pager"

section "FIM"
echo "Assessment concluído em $(date -Is)"
REMOTE_EOF

# Injeta as variáveis de configuração no início do script remoto.
REMOTE_PAYLOAD="DATA_DIR='${DATA_DIR}'
DB_PORT='${DB_PORT}'
LXD_BRIDGE='${LXD_BRIDGE}'
${REMOTE_SCRIPT}"

echo ">> Executando assessment (somente leitura)..." >&2
ssh "${SSH_OPTS[@]}" "${OUTE_HOST}" "bash -s | tee /tmp/oute_assessment.txt" \
  <<<"${REMOTE_PAYLOAD}" | tee "${LOCAL_REPORT}"

echo >&2
echo ">> Relatório local:    ${LOCAL_REPORT}" >&2
echo ">> Relatório no host:  ${OUTE_HOST}:/tmp/oute_assessment.txt" >&2
