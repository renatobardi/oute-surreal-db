#!/usr/bin/env bash
#
# upgrade_tailscale_host.sh — atualiza o Tailscale do HOST oute-server (roda no Mac, pede a senha do sudo).
#
# Por que um script e não um comando: o SSH até o host passa pelo próprio Tailscale. Reiniciar o
# tailscaled derruba a sessão; se o apt estivesse atrelado a ela, morreria no meio e deixaria o dpkg
# pela metade. Aqui o apt roda desacoplado (systemd-run), o script religa o SSH e confere o resultado.
# O host também sustenta os proxies LXD ligados ao IP Tailscale (UI do kubo etc.): o estado desses
# listeners é registrado antes e comparado depois (sem o escopo `%interface`, que versões novas do
# tailscaled passaram a exibir na porta do próprio daemon).
#
#   ./ops/upgrade_tailscale_host.sh --check   # só leitura: estado atual e versão-alvo
#   ./ops/upgrade_tailscale_host.sh           # atualiza (pede a senha do sudo UMA vez)
#
# Variável: OUTE_HOST (default oute-server)

set -euo pipefail

HOST="${OUTE_HOST:-oute-server}"
UNIT="ts-upgrade-$(date +%Y%m%d%H%M%S)"
QUIET_SSH=(-o BatchMode=yes -o ConnectTimeout=10)

r() { ssh "${QUIET_SSH[@]}" "${HOST}" "$@"; }
ok()   { printf '  [ok]    %s\n' "$*"; }
warn() { printf '  [AVISO] %s\n' "$*"; }
die()  { printf '  [ERRO]  %s\n' "$*" >&2; exit 1; }

snapshot() { # versão | ip | listeners nos IPs tailscale do host | tailscaled
  r 'ip="$(tailscale ip -4)"; echo "version=$(tailscale version | head -1)"; echo "ip=${ip}";
     echo "tailscaled=$(systemctl is-active tailscaled)";
     echo "listeners=$(ss -ltn | awk -v ip="${ip}" "index(\$4, ip) == 1 {print \$4}" | sed "s/%[^:]*//" | sort | tr "\n" " ")"'
}

echo ">> Estado atual do host"
BEFORE="$(snapshot)" || die "sem ssh para ${HOST}"
printf '%s\n' "${BEFORE}" | sed 's/^/   /'
OLD_VERSION="$(printf '%s\n' "${BEFORE}" | sed -n 's/^version=//p')"
TARGET="$(curl -fsS 'https://pkgs.tailscale.com/stable/?mode=json' | python3 -c 'import sys,json; print(json.load(sys.stdin)["TarballsVersion"])')" \
  || die "não consegui consultar a versão estável do Tailscale"
echo ">> Versão estável: ${TARGET} (host: ${OLD_VERSION})"
if [ "${OLD_VERSION}" = "${TARGET}" ]; then ok "o host já está na versão estável"; exit 0; fi

if [ "${1:-}" = "--check" ]; then echo ">> --check concluído; nada foi alterado."; exit 0; fi

echo ">> Atualizando (apt desacoplado da sessão; a conexão cai por alguns segundos, é esperado)"
# Uma única sessão com tty: o sudo pergunta a senha uma vez. systemd-run devolve na hora.
ssh -t "${HOST}" "sudo systemd-run --unit=${UNIT} --collect bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq --only-upgrade tailscale'" \
  || die "não consegui iniciar a atualização (senha do sudo?)"

echo ">> Aguardando o host voltar com a versão nova"
NEW_VERSION=""
for _ in $(seq 1 40); do
  sleep 6
  NEW_VERSION="$(r 'tailscale version | head -1' 2>/dev/null || true)"
  if [ -n "${NEW_VERSION}" ] && [ "${NEW_VERSION}" != "${OLD_VERSION}" ]; then break; fi
done
[ -n "${NEW_VERSION}" ] && [ "${NEW_VERSION}" != "${OLD_VERSION}" ] \
  || die "o host não reportou versão nova em ~4 min; verifique: ssh ${HOST} 'journalctl -u ${UNIT} --no-pager | tail'"

echo ">> Conferindo o estado depois"
sleep 5
AFTER="$(snapshot)"
printf '%s\n' "${AFTER}" | sed 's/^/   /'
FAIL=0
[ "$(printf '%s\n' "${AFTER}" | sed -n 's/^ip=//p')" = "$(printf '%s\n' "${BEFORE}" | sed -n 's/^ip=//p')" ] && ok "mesmo IP Tailscale" || { warn "IP Tailscale mudou"; FAIL=1; }
[ "$(printf '%s\n' "${AFTER}" | sed -n 's/^tailscaled=//p')" = "active" ] && ok "tailscaled ativo" || { warn "tailscaled não está ativo"; FAIL=1; }
[ "$(printf '%s\n' "${AFTER}" | sed -n 's/^listeners=//p')" = "$(printf '%s\n' "${BEFORE}" | sed -n 's/^listeners=//p')" ] \
  && ok "listeners dos proxies LXD iguais aos de antes" \
  || { warn "listeners diferentes dos de antes (proxies LXD podem precisar de restart): compare os blocos acima"; FAIL=1; }
echo
if [ "${FAIL}" -eq 0 ]; then echo ">> Concluído: ${OLD_VERSION} -> ${NEW_VERSION}, tudo igual ao estado anterior."; else echo ">> Atualizado (${OLD_VERSION} -> ${NEW_VERSION}), mas há avisos acima." >&2; exit 2; fi
