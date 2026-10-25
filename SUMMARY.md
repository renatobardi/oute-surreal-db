# Projeto: bancos de dados dos projetos Oute

Dois stacks isolados no `oute-server`, cada um num **LXC próprio** na `lxdbr0` (padrão da casa: todo projeto é um LXC com Docker dentro):

| Stack | Repo | Projetos | Motivo |
|---|---|---|---|
| **oute-surreal-db** | este | kubo, obo | grafo + vetores + documento no mesmo motor (kubo); FTS + vetores (obo) |
| **oute-supabase-db** | `renatobardi/oute-supabase-db` | hanko, frentes-engenharia, financial-control | relacional (Postgres), auth, storage, realtime |

Fora do escopo: **oute-agent** (SurrealDB próprio, ADR-08: dado derivado, isolado do agente yolo), **vaultwarden** (SQLite, isolado por segurança — cofre não depende de nenhum stack), **studio** (descontinuado).

## Decisões (2026-10-18)

- **Instância central** de SurrealDB (não embutida por projeto): é o propósito deste repo; novos projetos entram como namespace.
- **Databases `prd`/`test`**, criadas só onde o ambiente existe (`kubo:prd,test obo:prd`).
- **Dois usuários por database**: `app_<db>` OWNER (aplicação) e `ro_<db>` VIEWER (backup/leitura).
- **Pilotos**: kubo-test → kubo-prd → obo (surreal); financial-control → frentes-engenharia → hanko (supabase).
- **hanko** é app próprio: migra só o Postgres (`HANKO_DATABASE_URL`). Supabase Auth/Storage ficam como opção futura.
- **Repo oute-supabase-db**: reset para repo próprio só com `docker/` + nossos arquivos, sem amarra ao upstream (reescrita da `master` só com ok explícito).
- **LXC por stack**, não Docker no host. Isolamento por construção (rede, disco, Docker próprios), sem regras `DOCKER-USER`, sem choque de porta 8000 entre Supabase e SurrealDB, backup via `lxc snapshot`/`export`.
- **Achado (medido 2026-10-18):** containers Docker do host — inclusive a rede do agente yolo — alcançam IPs de LXC. LXC sozinho não isola do host. ACL do LXD não serve: o LXD 5.21 rejeita `security.acls` em NIC de bridge. Barreira adotada: **firewall nft dentro do LXC** (tabela própria `inet oute_sdb`, hook forward; só os IPs dos LXCs clientes chegam na 8000). O tráfego do Docker do host chega mascarado como `10.173.117.1`, fora da lista. Persistido em `/etc/nftables.conf`. Novo projeto cliente = novo IP na lista (`SURREAL_CLIENT_IPS` no script de ops). Vale também para os LXCs existentes (fora do escopo).
- SurrealDB **v3.3.0** por digest, RocksDB, `user 10001`, `mem_limit 2g`, `cpus 1`.
- Um **namespace por projeto** (hífen → underscore). Senhas no cofre (Vaultwarden).
- Acesso só pela `lxdbr0` (IP do LXC); dentro do LXC o compose publica `:8000`. Dados em `/srv/oute-surreal-db/data` (10001:10001).
- Backup: snapshot do LXC. Dump SurrealQL fica pra depois.
- Migração: `surreal export` na origem → `surreal import` no destino; origem viva até confirmar; rollback = URL antiga.

## O que cada projeto usa do SurrealDB (assessment de código, 2026-10-18)

| Projeto | Hoje | Uso | Migração |
|---|---|---|---|
| kubo (kubo-prd .21 / kubo-test .18) | 3.1.5 rocksdb, ns `kubo` db `kubo`, ~270 MB cada | RELATE/grafo, HNSW, SCHEMAFULL, live queries | v3→v3, direta. **Piloto** |
| obo (obo-prd .30) | 2.6.5 rocksdb, ns `obo` db `obo` | FTS (`search::`), vetores, `DEFINE FUNCTION`, EVENT | v2→v3: export/import + teste do app (SurrealQL v3 tem breaking changes) |

Achado: kubo e obo passam a senha root em `--pass` na linha de comando (visível em `docker inspect`). Aqui vai por env var.

## Assessment do servidor (2026-10-18)

- Ubuntu 24.04 aarch64 (Oracle), 4 vCPU, 23 GiB RAM (13 disponíveis), sem swap. Docker 29.1.3, LXD pool `oute-pool` em `/mnt/lxd` (115 GiB livres). `sudo` exige senha.
- `lxdbr0` = `10.173.117.1/24`. LXCs: kubo-prd/test, obo-prd, hanko-prd, frentes-engenharia-prd, financial-control-prd, vaultwarden, uptime-kuma, studio-prd/test (descontinuado).
- Relatórios completos em `reports/` (ignorado pelo git).

## Arquivos

- **Fonte da verdade**: `README.md` (índice), `docs/DESIGN.md` (desenho e decisões), `docs/OPERATIONS.md` (runbooks).
- `docker/docker-compose.yml`, `.env.example`, `scripts/init_surreal.sh` (idempotente; `--rotate [projeto]`), `scripts/oute-assessment.sh`, `ops/provision_lxc.sh`, `ops/rotate_and_show_credentials.sh`, `docs/plano.html`.
- Firewall de host e unit systemd do desenho anterior foram removidos: o LXC isola por construção.

## Perguntas abertas

Nenhuma.

## Fases

1. **Preparação** (esta branch): assessments, divisão, decisões, docs, compose/init para o LXC. ✔
2. **LXC oute-surreal-db** ✔ (2026-10-18): `10.173.117.50`, 2 CPU, 3 GiB, nesting, autostart, snapshots 7d (snapshot `pos-f2`); nft no LXC, `docker.io`, repo em `/opt/oute-surreal-db`, `.env` 600, compose, init. Verificado, inclusive após reboot do LXC: healthy; kubo-test alcança; vaultwarden e containers Docker do host (`bridge`, `oute-agent_oute`) bloqueados (13 drops no contador). Scripts versionados em `ops/` (`provision_lxc.sh`, `rotate_and_show_credentials.sh`). Pendente do dono: guardar credenciais no cofre.
3. **Piloto kubo-test** — *em andamento*: dados já importados no central (ver "Estado da F3"); falta o signin do kubo e a validação com o app.
4. **obo**: export v2 → import v3, rodada de testes do app.
5. **oute-supabase-db**: repo + LXC + pilotos (financial-control → frentes → hanko). Plano próprio naquele repo.
6. **Backup**: política de snapshots LXC.

## Achados da F3 (2026-10-19)

1. **RocksDB trava na carga em massa do dump do kubo-test (143 MB, 55 tabelas, 94.899 registros).** Reproduzido várias vezes em v3.3.0 e também numa instância temporária v3.1.5: o servidor para a 0% de CPU, o health check estoura e só reinicia com `docker restart`; sobra import parcial. Descartado por teste: memória (sem OOM, ~550 MiB de 2 GiB), CPU (2 CPUs igual), tamanho de statement (INSERTs de 12 MB passam), conteúdo/ID do registro (o registro "culpado" entra isolado em 37 ms, com schema completo e sem dados), ordem das arestas. Depende do estado acumulado de escrita. Config observada do RocksDB com `cpus 1`/`mem 2g`: 1 thread de background, 2 jobs, *memory manager* de 144 MiB, blobs ≥ 4 KB separados.
2. **Com engine `surrealkv` (v3.3.0) o mesmo dump importa em 31 s, 0 falhas**, com os 32 índices (incluindo HNSW de 768 dim). Contagem por tabela idêntica à origem (55 tabelas, 94.899 registros, 0 divergências) e busca KNN no HNSW funciona. Ordem usada: schema (sem índices) → `INSERT` normais → `INSERT RELATION` → `DEFINE INDEX`, **um statement por request** em `/import`.
3. **Modelo de auth do kubo não cabe no nosso modelo (usuários de database).** `kubo/store/client.py:124` faz `signin({"username","password"})` (root-level) e usa 3 credenciais **ROOT-level**: `root`, `kubo_rw` (EDITOR, escrita da UI) e `kubo_ro` (VIEWER). No central, usuário ROOT enxerga todos os namespaces (inclusive obo). Para migrar é preciso usuários de database (signin com `namespace`+`database`: mudança de 1 linha no kubo) e um **terceiro usuário `rw_<db>` (EDITOR)**, que nosso `init_surreal.sh` ainda não cria.

## Decisões tomadas após a F3 (2026-10-24)

- **Engine do central: `surrealkv`** (v3.3.0). Instância recriada; o RocksDB antigo (vazio, só usuários da F2) foi removido; snapshots `pre-surrealkv` e `pos-f3-kubo-test-import` guardam os estados.
- **Auth: usuários de database com três papéis** por database: `app_` OWNER, `rw_` EDITOR, `ro_` VIEWER. O kubo precisa mudar o signin (PR no repo do kubo). Nota: EDITOR **pode** fazer `DEFINE TABLE`; o que ele não pode é gerenciar usuários/acessos.
- **Reportar o travamento do RocksDB ao SurrealDB**: depois (não bloqueia).

## Estado da F3 (2026-10-24)

- **kubo-test roda no central desde 2026-10-24.** Código com signin de database (kubo #256), overlay `compose.central.yml` (kubo #258), imagem do CI por digest (`sha256:4c83…9a42`), deploy **manual** (ver abaixo). Validado: 3 credenciais (`app_test`/`rw_test`/`ro_test`) autenticam, migrations reconhecem o banco importado (`applied=[]`), digest-guard e health-guard OK, UI responde (`/login` 200, `/healthz` 200), 0 erros nos logs, e uma escrita pelo caminho `rw_test` aparece no central e **não** no banco local.
- Dados importados duas vezes, a segunda com os escritores parados: 55 tabelas, 96.066 registros, 0 divergências, KNN do HNSW ok.
- **O banco local do kubo-test (`kubo-surrealdb-1`) e o sidecar de backup seguem rodando, sem uso.** A partir de agora o local está desatualizado em relação ao central. Rollback (`.env.pre-central` + `--profile local-db`, ou `lxc restore kubo-test pre-central`) perde o que for escrito no central depois da troca. Desligar o banco local depois do período de validação.
- Rollback: `~/.env.pre-central` no kubo-test + `docker compose --profile local-db up -d`, ou `lxc restore`. Snapshots: kubo-test `pre-cd-redeploy`, `pre-central`; central `pre-kubo-test-reimport` (expiram em 7 dias).
- Falta: período de validação com o app real, depois kubo-prd (mesmo procedimento, database `prd`).

### CD do kubo reparado (2026-10-24) e pendências

O CD voltou a funcionar de ponta a ponta (merge na `main` → build → deploy no kubo-test pelo digest, com digest-guard e health-guard; PRD continua só por promoção manual). Eram **três camadas**, nesta ordem:
1. O auth key do Tailscale `kubo-cd-dev` expirou em 23/10 (chaves duram no máximo 90 dias): renovado em `TS_AUTHKEY_DEV`. A `kubo-cd-prd` também expirou (renovar antes do próximo deploy em PRD).
2. O nó do kubo-test saiu da tailnet (`NeedsLogin`): reautenticado pelo link de login (mesmo IP, `KUBO_TEST_HOST` ficou como estava) e com expiração de chave desligada.
3. **A regra de SSH da ACL só aceita destinos com `tag:cd-dev` ou `tag:cd-prd`**, e o login interativo devolve o nó sem tag (dispositivo do usuário). Correção, sem editar a ACL e sem passar pelo painel: `tailscale up --ssh --advertise-tags=tag:cd-dev` dentro do LXC (o usuário é `autogroup:admin`, dono da tag). Vale para qualquer nó que perca a tag num re-login.

Também: o `rsync --delete` do CD limpa tudo em `~/kubo` que não está no repo e já apagou o backup do `.env`. Ele agora vive em `~/.env.pre-central` (fora de `~/kubo`), e o script e o runbook do kubo foram ajustados (kubo #260).

Tailscale dos nós atualizado para a 1.104.2 (kubo-test, kubo-prd, vaultwarden, uptime-kuma e o host, este com `ops/upgrade_tailscale_host.sh`).

Pendências:
1. **`deploy-remote.sh` não conhece o overlay central**: ele sobe `surrealdb` pelo nome, o que reinicia o banco local a cada deploy (foi o que se viu: `kubo-surrealdb-1` "Up 10 minutes" logo depois do CD). Ajustar antes de desligar o banco local.
2. **Credenciais expostas numa conversa**: as senhas do central (incluindo a `root`) apareceram em texto. Risco baixo (só os IPs da allowlist conectam); rotacionar junto com a migração do kubo-prd (`./ops/rotate_and_show_credentials.sh` + `scripts/ops/kubo-test-use-central.sh`).

### Como o deploy manual foi feito (fallback, caso o CD quebre de novo)

Com o digest que o CI já publicou (`build` verde), sem build local: sincronizar os arquivos do commit (`git archive origin/main | ssh oute-server 'lxc exec kubo-test -- sudo -u ubuntu -H tar -x -C /home/ubuntu/kubo'`) e rodar `scripts/deploy-remote.sh sha256:<digest>` como `ubuntu` dentro do LXC (em segundo plano, com log). Os guards do script (digest e saúde) valem igual. Requer autorização explícita do dono (AGENTS.md do kubo).

## Preview do obo (v2.6.5 → v3.3.0), com export v2 sintético

- O export v2.6.5 tem o mesmo formato do v3 (`INSERT`, `INSERT RELATION`), com `DEFINE FUNCTION` multi-linha: dados, strings difíceis e funções importam.
- **A sintaxe de índice do v2 é rejeitada pelo v3** (`SEARCH ANALYZER … BM25(…) DOC_IDS_ORDER …`): a ferramenta para com o erro do servidor (exit 1).
- **MTREE e o operador KNN `<|k|>` não existem mais no v3**: é preciso HNSW e `<|k,EF|>` (muda schema e queries do obo).
- Arestas v2 trazem um campo lixo `__: true`, que o v3 grava como campo.
- Conclusão: migrar o obo exige **adaptar schema de índices e queries**, não só export/import. Planejar como trabalho do obo na F4.
