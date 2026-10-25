# Operação (runbooks)

Pré-requisitos: `ssh oute-server` funcionando (chave, sem senha) e `lxc` sem sudo (usuário `ubuntu`).
Scripts `ops/*` rodam **no seu Mac**, na raiz do repo, e enviam para o servidor o **HEAD commitado** (`git archive`): commite antes.
Convenção nos exemplos: `L="ssh oute-server lxc exec oute-surreal-db --"`.

> Armadilha: `lxc exec` consome o stdin. Dentro de scripts/heredocs use `</dev/null` nos `lxc exec` que não precisam de entrada.

## 1. Saúde e estado

```sh
ssh oute-server 'lxc list oute-surreal-db -c ns4 -f csv'                      # RUNNING + IP 10.173.117.50
ssh oute-server 'lxc exec oute-surreal-db -- docker ps --format "{{.Names}} {{.Status}}"'   # healthy
ssh oute-server 'lxc exec oute-surreal-db -- nft list chain inet oute_sdb sdb_forward'      # firewall + contador de drops
ssh oute-server 'lxc exec oute-surreal-db -- docker logs --tail 50 oute-surreal-db'
```

## 2. Conectar uma aplicação

- Endpoint: `ws://10.173.117.50:8000/rpc` (SDK) ou `http://10.173.117.50:8000`.
- Usuários por database: `app_<db>` (OWNER: DDL/migrations e dados), `rw_<db>` (EDITOR: dados e schema, **não** gerencia usuários/acessos; caminho de escrita da UI) e `ro_<db>` (VIEWER: leitura/backup).
- Os usuários são **de database**: no SDK faça signin com `namespace`, `database`, `username`, `password`; no CLI use `--auth-level database`.
- Env vars (padrão a adotar em cada app ao migrar): `SURREAL_URL`, `SURREAL_NS`, `SURREAL_DB`, `SURREAL_USER`, `SURREAL_PASS`.
- Senhas vêm do Vaultwarden (`oute-surreal-db/<ns>/<db>/<usuário>`). Nunca em argumento de linha de comando nem no git.
- O LXC do app **precisa estar na lista de clientes** (seção 3), senão a conexão é derrubada pelo firewall.

Teste rápido a partir de um LXC cliente:
```sh
ssh oute-server 'lxc exec kubo-test -- bash -c "curl -s http://10.173.117.50:8000/health -o /dev/null -w %{http_code}"'   # 200
```

## 3. Adicionar um projeto cliente (novo IP autorizado)

Sintoma de esquecer: o app não conecta (timeout), e o contador de drops do nft sobe.

1. Descubra o IP do LXC do projeto (`ssh oute-server 'lxc list -c n4 -f csv'`). O IP deve ser **fixo** (device `eth0` com `ipv4.address`).
2. Em `ops/provision_lxc.sh`, acrescente o IP à lista padrão `SURREAL_CLIENT_IPS` e commite (PR). Para um teste pontual, passe por variável: `SURREAL_CLIENT_IPS="… novo" ./ops/provision_lxc.sh`.
3. Rode `./ops/provision_lxc.sh`. Ele reaplica o firewall, reenvia o repo, sobe o compose e **testa o negativo** (deve terminar com `isolamento verificado`).
4. Se o projeto também precisa de namespace/database, siga a seção 4.

## 4. Adicionar projeto/namespace ou database (ambiente)

Formato de `SURREAL_PROJECTS`: `projeto:db1,db2` separados por espaço, **só ambientes que existem** (ex.: `kubo:prd,test obo:prd`).

1. Atualize o default em `.env.example` e commite (documentação).
2. O `.env` do LXC **não** é sobrescrito pelo provisionamento: edite-o lá.
   ```sh
   ssh -t oute-server 'lxc exec oute-surreal-db -- vi /opt/oute-surreal-db/.env'
   ```
3. Rode `./ops/provision_lxc.sh` (reenvia o repo, mantém `.env`, roda o init: cria só o que falta e mantém usuários existentes) ou, só o init:
   ```sh
   ssh oute-server 'lxc exec oute-surreal-db -- bash -c "cd /opt/oute-surreal-db && ./scripts/init_surreal.sh"' </dev/null
   ```
4. As senhas dos usuários novos aparecem **uma vez**; guarde no Vaultwarden.

## 5. Credenciais

- Ver/gerar tudo no seu terminal: `./ops/rotate_and_show_credentials.sh` (**gera senhas novas para todos** e mostra a senha root). Use só enquanto nenhum app depende delas.
- Rotacionar um projeto: `ssh oute-server 'lxc exec oute-surreal-db -- bash -c "cd /opt/oute-surreal-db && ./scripts/init_surreal.sh --rotate kubo"' </dev/null` (a saída traz as senhas novas; atualize o app e o cofre).
- Senha root: só no `.env` do LXC (600) e no cofre. Trocá-la exige editar `SURREAL_ROOT_PASS` no `.env` **e** alterar a senha no próprio banco (o `SURREAL_PASS` do container só vale na criação do root: o log avisa que root existente não é recriado). *Procedimento ainda não exercitado.*
- Nada é gravado em disco pelos scripts; o terminal é o único destino das senhas.

## 6. Snapshots (backup provisório)

```sh
ssh oute-server 'lxc snapshot oute-surreal-db antes-de-X'       # criar (faça antes de migração/upgrade)
ssh oute-server 'lxc info oute-surreal-db | sed -n "/Snapshots/,\$p"'
ssh oute-server 'lxc restore oute-surreal-db antes-de-X'        # volta o LXC INTEIRO (dados, config) àquele ponto
```

- Snapshots expiram em 7 dias (`snapshots.expiry`). Não é política de backup: `/mnt/lxd` não tem backup OCI (fase F6 pendente).
- `restore` descarta tudo escrito depois do snapshot.

## 7. Atualizar a versão do SurrealDB

1. Snapshot (seção 6).
2. Troque `SURREAL_IMAGE` (tag **e** digest) em `.env.example`, commite, e edite o `.env` do LXC.
3. `ssh oute-server 'lxc exec oute-surreal-db -- bash -c "cd /opt/oute-surreal-db && docker compose --env-file .env -f docker/docker-compose.yml up -d"' </dev/null`; confirme `healthy`.
4. Salto de versão maior (ex.: 2 → 3) pode exigir export/import e revisão de SurrealQL: trate como migração (seção 8).

## 8. Migrar os dados de um projeto para cá

Método: export na origem → `scripts/import_dump.py` no destino. A **origem fica viva** até a confirmação; rollback = voltar as env vars do app para a origem.

1. Snapshot do LXC destino (seção 6).
2. Exportar da origem **por pipe, sem passar por disco do host**, para um arquivo temporário dentro do LXC do central (exemplo kubo, usando o sidecar de backup dele, que já tem as credenciais):
   ```sh
   ssh oute-server 'lxc exec kubo-test -- docker exec kubo-backup-1 sh -c '"'"'AUTH=$(printf "%s:%s" "$SURREAL_USER" "$SURREAL_PASS" | base64 | tr -d "\n"); wget -q -O - --header="Authorization: Basic $AUTH" --header="surreal-ns: $SURREAL_NS" --header="surreal-db: $SURREAL_DB" http://surrealdb:8000/export'"'"' </dev/null | lxc exec oute-surreal-db -- sh -c "cat > /root/dump.surql"'
   ```
3. Importar no database novo (`prd`/`test`; o nome muda se a origem era `<projeto>/<projeto>`), de dentro do LXC do central:
   ```sh
   ssh oute-server 'lxc exec oute-surreal-db -- sh -c "cd /opt/oute-surreal-db && set -a && . ./.env && set +a && SURREAL_ENDPOINT=http://127.0.0.1:8000 SURREAL_PASS=\"\$SURREAL_ROOT_PASS\" python3 scripts/import_dump.py /root/dump.surql <ns> <db>"' </dev/null
   ```
   `--dry-run` mostra só o plano. A ferramenta envia schema → dados → arestas → índices em lotes, **ignora `DEFINE USER/ACCESS` do dump**, recusa `UPDATE` (no v3 não cria registro) e aborta antes de enviar se houver statement desconhecido.
4. **Conferir sempre**: o `/import` responde `[]` no sucesso e o `OPTION IMPORT` desliga coerção de tipo e `ENFORCED`, então "sem erro" não prova nada. Compare contagem por tabela origem × destino, índices e `DEFINE FUNCTION`; se houver HNSW, rode uma busca KNN.
5. Se o destino já tem dados de uma tentativa anterior, **limpe antes** (tabelas, não usuários; ver armadilhas). Apagar o dump do LXC (`rm /root/dump.surql`): é dado sensível.
6. Apontar o app (ou um ambiente de teste dele) para o destino com `app_<db>`/`rw_<db>`/`ro_<db>`; validar fluxos reais.
7. Só depois de confirmado, desligar a origem (decisão do dono).

Resultado medido (kubo-test, 2026-10-24): 55 tabelas, 96.066 registros, 0 divergências, import em 28 s no `surrealkv`.
Ordem: **kubo-test → kubo-prd → obo**. kubo: v3.1.5 → v3.3.0, direto. **obo: v2.6.5 → v3.3.0 não é só export/import**: o v3 rejeita a sintaxe de índice do v2 (`SEARCH ANALYZER … BM25(…) DOC_IDS_ORDER …`), removeu MTREE e o operador KNN `<|k|>` (use HNSW e `<|k,EF|>`), e as arestas v2 trazem um campo `__: true` que vira lixo. Adapte schema e queries do obo antes.

## 9. Recriar/atualizar o LXC (idempotente)

```sh
./ops/provision_lxc.sh --check   # só pré-condições, não altera nada
./ops/provision_lxc.sh           # cria/atualiza: config do LXC, IP fixo, Docker, firewall, repo, compose, init e verificação
```
- Se o LXC já existe, ele é atualizado (repo reenviado, compose `up -d`, init mantém usuários, `.env` e senha root preservados).
- Variáveis: `OUTE_HOST`, `LXC_NAME`, `LXC_IP`, `LXC_CPU`, `LXC_MEM`, `SURREAL_CLIENT_IPS`, `POS_LXC` (deve alcançar), `NEG_LXC` (não pode alcançar).
- Termina com `isolamento verificado` (exit 0) ou falha (exit 2) se algo vazar; **não migre dados com a verificação falha**.
- Se o LXC for **perdido**: o script recria tudo, mas os **dados só voltam de um snapshot/export**.

## 10. Servidor (referência)

Ubuntu 24.04 aarch64 (Oracle Cloud), 4 vCPU, 23 GiB RAM, sem swap; LXD 5.21.8 LTS; pool `oute-pool` (`/mnt/lxd`, dir). `sudo` exige senha (nenhum runbook precisa dele). O assessment read-only é `./scripts/oute-assessment.sh` (relatórios em `reports/`, ignorado pelo git).

## 11. Trocar o engine do central (procedimento usado em 2026-10-24: RocksDB → surrealkv)

Só com o central **vazio** ou com backup/export dos dados (um engine novo começa sem nada).
1. `lxc snapshot oute-surreal-db pre-<engine>`.
2. No LXC: `docker compose ... down`; mover (não apagar) o diretório de dados: `mv /srv/oute-surreal-db/data /srv/oute-surreal-db/data-<engine-antigo>` e recriar `data` com dono `10001:10001`.
3. Ajustar o engine em `docker/docker-compose.yml` (URL do storage), commitar, `./ops/provision_lxc.sh` (recria o container e roda o init).
4. O init cria **usuários novos com senhas novas**: rode `./ops/rotate_and_show_credentials.sh` e guarde no cofre.
5. Reimportar os dados (seção 8) e conferir. Depois de validar, apagar o diretório antigo.

## 12. Cutover do kubo para o central (test e prd)

Fluxo em 3 passos, os mesmos validados no kubo-test (ensaiados de novo ponta a ponta em 2026-10-24):

1. **Dados**: `./ops/migrate_kubo_data.sh <test|prd>` (pára os escritores do kubo, snapshot do central, exporta o banco local por pipe, limpa o destino, importa com `scripts/import_dump.py` e **confere** contagem por tabela e KNN; só apaga o dump depois de conferir). Se a conferência falhar, os escritores continuam parados e o script mostra o comando para retomar o banco local.
2. **Config do kubo**: no repo do kubo, `scripts/ops/kubo-<test|prd>-use-central.sh` (pede as 3 senhas no terminal; guarda o `.env` em `~/.env.pre-central`; soma o overlay `compose.central.yml`).
3. **Subir**: `./ops/start_kubo_on_central.sh <test|prd>` (prova `app`/`ro`/`rw`, recria api+scheduler na mesma imagem, digest-guard + health-guard, smoke com escrita no central).

Cada script tem `--check` (só leitura). Pré-requisito do prd: o kubo de produção precisa estar com o código novo (signin de database e o arquivo `compose.central.yml`), o que vem da promoção do CD para PRD.

**Não tire snapshot do LXC kubo-prd** para esse cutover: no pool `dir` o snapshot congela a instância por minutos (em produção seria indisponibilidade). O rollback do prd não precisa dele: o banco local não é tocado e `~/.env.pre-central` guarda a config anterior (`docker compose --profile local-db up -d`).

## 13. Armadilhas conhecidas

| Sintoma | Causa / ação |
|---|---|
| `Invalid device option "security.acls"` | LXD 5.21 não aceita ACL em NIC de bridge; usamos nft no LXC |
| nft: `syntax error, unexpected fwd` | `fwd` é palavra reservada; a chain se chama `sdb_forward` |
| Script remoto "morre" no meio | `lxc exec` consumiu o stdin; use `</dev/null` |
| `There was a problem with authentication` com `app_`/`ro_` | falta `--auth-level database` (usuários são de database) |
| `onnxruntime cpuid_info warning` | ruído inofensivo do SurrealDB; ignore |
| Import trava / servidor a 0% CPU / health `unhealthy` | Era o RocksDB na carga em massa (agora o engine é `surrealkv`). `docker restart` e `lxc restore` do snapshot pré-import |
| Script remoto com `pkill -f nome` mata o próprio shell | O padrão aparece na linha de comando do próprio shell; use `pgrep -f "[n]ome"` em comando separado |
| `/import` diz OK mas faltam dados / dado com tipo errado | `OPTION IMPORT` desliga validação e o sucesso volta `[]`; confira contagens. `UPDATE` no v3 não cria registro (use `UPSERT`; a ferramenta recusa `UPDATE`) |
| EDITOR consegue `DEFINE TABLE` | É o comportamento do papel: ele só não gerencia usuários/acessos. Use OWNER só onde precisa de DDL de usuários |
| `lxc snapshot` trava a instância por minutos | No pool `dir` o snapshot copia o rootfs com a instância **congelada** (kubo-test: ~6 min, `Error: Instance is frozen`). Rode em segundo plano e acompanhe `lxc operation list`; não interrompa |
| Reimportar num database que já tem tabelas falha (`DEFINE TABLE` sem OVERWRITE) | Limpar antes, preservando os usuários: como root, `INFO FOR DB;` e `REMOVE TABLE <t>;` para cada tabela. Não use `REMOVE DATABASE` (leva os usuários junto) |
| Script ops que escreve arquivo via `lxc exec` deixa o arquivo `root:root` | `lxc exec` roda como root: use `sudo -u <dono> -H` ou restaure o dono (`chown`) |
| Nó do Tailscale perdeu a tag depois de um re-login e o SSH do CD é recusado (`tailnet policy does not permit you to SSH`) | A regra de SSH só aceita destinos com `tag:cd-dev`/`tag:cd-prd`. No LXC: `tailscale up --ssh --advertise-tags=tag:cd-dev` (ou `cd-prd`) |
| Auth key do Tailscale expirou (`invalid key: API key … not valid`) | Chaves duram no máximo 90 dias: gerar outra (sem tag, como a anterior) e atualizar o secret do environment no GitHub |
| Script remoto "passa" mas só a 1ª verificação rodou (`docker compose run`/`exec` dentro de `bash -s`) | Esses comandos leem o stdin e engolem o resto do script: use `</dev/null` e faça o script **exigir** a saída esperada (ver a prova das 3 credenciais em `start_kubo_on_central.sh`) |
| `DEFINE USER` não troca senha | por desenho o init mantém existentes; use `--rotate` |
| Container Docker do host "alcança" LXCs vizinhos | verdade para os **outros** LXCs (fora do escopo); este está protegido pelo nft |
| `.env.example` mudou e nada aconteceu no LXC | o `.env` do LXC não é sobrescrito; edite-o (seção 4) |
