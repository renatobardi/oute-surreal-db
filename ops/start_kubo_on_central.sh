#!/usr/bin/env bash
#
# start_kubo_on_central.sh <test|prd> — sobe scheduler e api do kubo apontando para a instância central,
# com os mesmos guards do deploy (digest e saúde) e um smoke que PROVA que o app grava no central.
# Roda no Mac. Pré-requisito: `.env` do servidor já com o overlay compose.central.yml, SURREAL_AUTH_LEVEL=database
# e as credenciais (repo do kubo: scripts/ops/kubo-<env>-use-central.sh) e os dados já copiados e
# conferidos (ops/migrate_kubo_data.sh).
#
# Passos: pré-checagens -> prova das 3 credenciais (app/rw/ro) -> recria api+scheduler na MESMA imagem que
# já roda -> digest-guard + health-guard -> smoke (UI, logs, escrita rw no central e leitura ro).
#
#   ./ops/start_kubo_on_central.sh test --check   # só pré-checagens
#   ./ops/start_kubo_on_central.sh test           # sobe e valida
#
# Rollback (se algo falhar): restaurar ~/.env.pre-central sobre ~/kubo/.env e
#   docker compose --profile local-db up -d   (banco local volta com os dados de antes da troca).

set -euo pipefail

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[[ $# -ge 1 ]] || usage
ENVNAME="$1"; shift
case "${ENVNAME}" in test|prd) ;; *) usage ;; esac
CHECK_ONLY=0
[[ "${1:-}" = "--check" ]] && CHECK_ONLY=1

HOST="${OUTE_HOST:-oute-server}"
KUBO_LXC="kubo-${ENVNAME}"
CENTRAL="${CENTRAL_LXC:-oute-surreal-db}"
DB="${ENVNAME}"

ok()   { printf '  [ok]    %s\n' "$*"; }
die()  { printf '  [ERRO]  %s\n' "$*" >&2; exit 1; }
step() { printf '\n>> %s\n' "$*"; }
rx() { ssh -o BatchMode=yes -o ConnectTimeout=10 "${HOST}" "$@"; }
# executa um script (stdin) como ubuntu dentro do LXC do kubo, com a mesma COMPOSE_FILE/KUBO_IMAGE do deploy
kubo_sh() { rx "lxc exec ${KUBO_LXC} -- sudo -u ubuntu -H bash -s"; }

PROOF="$(mktemp)"
trap 'rm -f "${PROOF}"' EXIT

PRELUDE='set -euo pipefail
cd ~/kubo
export COMPOSE_FILE="$(sed -n "s/^COMPOSE_FILE=//p" .env | tail -n1):compose.cd.yml"
export KUBO_IMAGE="$(docker inspect kubo-kubo-api-1 --format "{{.Config.Image}}")"
'

step "Pré-checagens (${KUBO_LXC} -> central, database kubo/${DB})"
rx true || die "sem ssh para ${HOST}"
kubo_sh <<'REMOTE' || die "o .env/overlay de ${KUBO_LXC} não está pronto para o central"
cd ~/kubo
test -f compose.central.yml || { echo "compose.central.yml ausente (faça o deploy do kubo com o overlay)"; exit 1; }
grep -q "^COMPOSE_FILE=.*compose.central.yml" .env || { echo "COMPOSE_FILE do .env não inclui compose.central.yml"; exit 1; }
grep -q "^SURREAL_AUTH_LEVEL=database" .env || { echo "SURREAL_AUTH_LEVEL=database ausente no .env"; exit 1; }
for k in SURREAL_URL SURREAL_USER SURREAL_PASS KUBO_RW_SURREAL_USER KUBO_RW_SURREAL_PASS KUBO_RO_SURREAL_USER KUBO_RO_SURREAL_PASS; do
  grep -qE "^${k}=.+" .env || { echo "chave ausente no .env: ${k}"; exit 1; }
done
echo "  [ok]    .env com overlay, auth de database e as 3 credenciais"
REMOTE
rx "lxc exec ${CENTRAL} -- sh -c 'docker inspect -f \"{{.State.Health.Status}}\" oute-surreal-db'" </dev/null | grep -qx healthy || die "central não está healthy"
ok "central healthy"
[[ "${CHECK_ONLY}" -eq 0 ]] || { echo; echo ">> --check concluído; nada foi alterado."; exit 0; }

step "Provando as 3 credenciais contra o central (execuções descartáveis, nada sobe ainda)"
{ printf '%s' "${PRELUDE}"; cat <<'REMOTE'
# `docker compose run -T` lê o stdin: sem </dev/null ele engole o resto deste script.
docker compose run -T --rm kubo-scheduler python -c "
from kubo.store import client
cfg = client.config()
with client.connect(cfg) as db:
    print('  [ok]    app:', cfg.user, cfg.auth_level, '->', db.query('RETURN 1;'))
" </dev/null
docker compose run -T --rm kubo-scheduler python -m kubo.store.migrations </dev/null 2>&1 | tail -1 | sed 's/^/          migrations: /'
docker compose run -T --rm kubo-api python -c "
from kubo.store import client
for label, cfg in (('ro', client.config()), ('rw', client.rw_config())):
    with client.connect(cfg) as db:
        print('  [ok]   ', label + ':', cfg.user, cfg.auth_level, '->', db.query('RETURN 1;'))
" </dev/null
REMOTE
} | kubo_sh > "${PROOF}" 2>&1 || { cat "${PROOF}"; die "alguma credencial não autentica no central. Nada foi iniciado."; }
cat "${PROOF}"
# a prova só vale se as TRÊS credenciais apareceram (guarda contra comando engolido/saída truncada)
for who in "app:" "ro:" "rw:"; do
  grep -q "\[ok\] *${who}" "${PROOF}" || die "prova incompleta: faltou a linha da credencial ${who%:}. Nada foi iniciado."
done
grep -q "migrations" "${PROOF}" || die "prova incompleta: faltou o resultado das migrations. Nada foi iniciado."

step "Recriando api e scheduler (mesma imagem que já roda) e rodando os guards"
{ printf '%s' "${PRELUDE}"; cat <<'REMOTE'
echo "  imagem: ${KUBO_IMAGE%%@*}@${KUBO_IMAGE##*@}" | cut -c1-110
docker compose up -d --no-build --force-recreate kubo-api kubo-scheduler 2>&1 | grep -E "Recreated|Started|Error" | sed 's/^/  /'
if [[ "${KUBO_IMAGE}" == *@sha256:* ]]; then
  HEX="${KUBO_IMAGE##*@sha256:}"
  bash scripts/digest-guard.sh "${HEX}" kubo-api 2>&1 | grep "\[digest-guard\]"
  bash scripts/digest-guard.sh "${HEX}" kubo-scheduler 2>&1 | grep "\[digest-guard\]"
else
  echo "  [aviso] imagem sem digest (build local): digest-guard pulado"
fi
bash scripts/health-guard.sh kubo-api --mode healthy --timeout 90 2>&1 | grep "\[health-guard\]"
bash scripts/health-guard.sh kubo-scheduler --mode stable --timeout 90 2>&1 | grep "\[health-guard\]"
REMOTE
} | kubo_sh || die "guards falharam. Rollback: restaurar ~/.env.pre-central e subir com --profile local-db"

step "Smoke: UI, logs e prova de que o app grava no central"
UI_ADDR="$(rx "lxc config device show ${KUBO_LXC}" </dev/null | sed -n 's/^ *connect: tcp://p' | head -1)"
[[ -n "${UI_ADDR}" ]] || UI_ADDR="$(rx "lxc config device get ${KUBO_LXC} eth0 ipv4.address" </dev/null):3900"
for p in /login /healthz; do
  # NOSONAR (shell:S5332): http de propósito: tráfego ssh -> bridge privada do LXD até a UI do kubo; a exposição real é WireGuard/Tailscale
  code="$(rx "curl -s -o /dev/null -m 8 -w %{http_code} http://${UI_ADDR}${p}" </dev/null)" # NOSONAR
  # NOSONAR
[[ "${code}" = 200 ]] && ok "UI ${p} -> 200" || die "UI ${p} -> ${code}"  # NOSONAR
done
{ printf '%s' "${PRELUDE}"; cat <<'REMOTE'
n="$(docker compose logs --since 3m kubo-api kubo-scheduler 2>&1 | grep -ciE 'traceback|"level": "error"|\[error|exception|authentication|not allowed' || true)"
[[ "${n}" = 0 ]] && echo "  [ok]    0 erros nos logs (3 min)" || { echo "  [ERRO]  ${n} ocorrências de erro nos logs"; exit 1; }
docker compose exec -T kubo-api python -c "
from kubo.store import client
with client.connect_rw() as rw:
    rw.query('CREATE zz_smoke:probe SET by = \"start_kubo_on_central\";')
with client.connect() as ro:
    got = ro.query('SELECT VALUE by FROM zz_smoke;')
print('  [ok]    escrita rw -> leitura ro:', got)
assert got == ['start_kubo_on_central'], got
" </dev/null
REMOTE
} | kubo_sh || die "smoke de escrita/leitura falhou"
rx "lxc exec ${CENTRAL} -- sh -c 'cd /opt/oute-surreal-db && set -a && . ./.env && set +a && python3 -'" <<PY
import base64, json, os, urllib.request
def q(s):
    r = urllib.request.Request("http://127.0.0.1:8000/sql", data=s.encode(), method="POST", headers={
        "Authorization": "Basic " + base64.b64encode(("root:" + os.environ["SURREAL_ROOT_PASS"]).encode()).decode(),
        "surreal-ns": "kubo", "surreal-db": "${DB}", "Accept": "application/json"})
    return json.loads(urllib.request.urlopen(r, timeout=60).read())
assert q("SELECT VALUE by FROM zz_smoke;")[0]["result"] == ["start_kubo_on_central"], "o registro de teste não está no central"
q("REMOVE TABLE zz_smoke;")
print("  [ok]    o registro de teste está no central (kubo/${DB}); removido")
PY

step "Concluído: ${KUBO_LXC} roda no central (kubo/${DB})"
echo "  Banco local e sidecar de backup seguem rodando, sem uso. Desligue-os só depois do período de validação."
