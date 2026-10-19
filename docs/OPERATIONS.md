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
- Usuário: `app_<db>` (OWNER) para a aplicação; `ro_<db>` para leitura/backup.
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

Método: `surreal export` na origem → `surreal import` no destino. A **origem fica viva** até a confirmação; rollback = voltar as env vars do app para a origem.

1. Snapshot do LXC destino (seção 6) e, se possível, cópia do dado de origem.
2. Exportar da origem (no LXC do projeto, container SurrealDB dele), com o usuário root **de lá**:
   `docker exec <container> /surreal export --endpoint http://127.0.0.1:8000 --user root --pass "$SENHA" --ns <ns> --db <db> /tmp/dump.surql`
   (passe a senha por variável de ambiente, não digitada em histórico compartilhado).
3. Importar no destino, no database novo (`prd`/`test`; o nome muda se a origem era `<projeto>/<projeto>`):
   `surreal import --endpoint http://10.173.117.50:8000 --user root --pass "$SENHA" --ns <ns> --db <prd|test> dump.surql`
4. Conferir contagens por tabela, índices/HNSW/analyzers e `DEFINE FUNCTION` (obo).
5. Apontar o app (ou um ambiente de teste dele) para o destino com `app_<db>`; validar fluxos reais.
6. Só depois de confirmado, desligar a origem (decisão do dono).

Ordem: **kubo-test → kubo-prd → obo**. kubo é v3.1.5 → v3.3.0 (direto). obo é v2.6.5 → v3.3.0 (breaking changes de SurrealQL: testar o app antes de apontar prd).
**O que a F3 ensinou (2026-10-19, kubo-test, 143 MB):**
- O export por `/export` é rápido (4 s) e pode ser **enviado por pipe entre LXCs sem passar por disco do host**.
- **No RocksDB do central o import travou** (v3.3.0 e v3.1.5): servidor a 0% CPU, health check estoura, precisa `docker restart`, sobra import parcial (recupere com `lxc restore` de um snapshot tirado antes). Com `surrealkv` o mesmo dump entrou em 31 s sem falhas e com contagens idênticas. **Não migre dados enquanto a decisão de engine estiver pendente** (`SUMMARY.md`).
- Ordem que funcionou: schema (sem índices) → `INSERT` normais → `INSERT RELATION` → `DEFINE INDEX`, **um statement por request** em `POST /import` (com `OPTION IMPORT;` na frente). Valide com contagem por tabela origem × destino e, se houver HNSW, uma busca KNN.
- O app precisa autenticar no nível certo: apps com credencial ROOT (kubo hoje) não cabem no central (ROOT enxerga todos os namespaces).

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

## 11. Armadilhas conhecidas

| Sintoma | Causa / ação |
|---|---|
| `Invalid device option "security.acls"` | LXD 5.21 não aceita ACL em NIC de bridge; usamos nft no LXC |
| nft: `syntax error, unexpected fwd` | `fwd` é palavra reservada; a chain se chama `sdb_forward` |
| Script remoto "morre" no meio | `lxc exec` consumiu o stdin; use `</dev/null` |
| `There was a problem with authentication` com `app_`/`ro_` | falta `--auth-level database` (usuários são de database) |
| `onnxruntime cpuid_info warning` | ruído inofensivo do SurrealDB; ignore |
| Import trava / servidor a 0% CPU / health `unhealthy` | Carga em massa no RocksDB (ver seção 8). `docker restart` e `lxc restore` do snapshot pré-import |
| Script remoto com `pkill -f nome` mata o próprio shell | O padrão aparece na linha de comando do próprio shell; use `pgrep -f "[n]ome"` em comando separado |
| `DEFINE USER` não troca senha | por desenho o init mantém existentes; use `--rotate` |
| Container Docker do host "alcança" LXCs vizinhos | verdade para os **outros** LXCs (fora do escopo); este está protegido pelo nft |
| `.env.example` mudou e nada aconteceu no LXC | o `.env` do LXC não é sobrescrito; edite-o (seção 4) |
