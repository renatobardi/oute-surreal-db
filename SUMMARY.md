# Projeto: bancos de dados dos projetos Oute

Dois stacks isolados no `oute-server`, cada um num **LXC próprio** na `lxdbr0` (padrão da casa: todo projeto é um LXC com Docker dentro):

| Stack | Repo | Projetos | Motivo |
|---|---|---|---|
| **oute-surreal-db** | este | kubo, obo | grafo + vetores + documento no mesmo motor (kubo); FTS + vetores (obo) |
| **oute-supabase-db** | `renatobardi/oute-supabase-db` | hanko, frentes-engenharia, financial-control | relacional (Postgres), auth, storage, realtime |

Fora do escopo: **oute-agent** (SurrealDB próprio, ADR-08: dado derivado, isolado do agente yolo), **vaultwarden** (SQLite, isolado por segurança — cofre não depende de nenhum stack), **studio** (descontinuado).

## Decisões (2026-10-18)

- **LXC por stack**, não Docker no host. Isolamento por construção (rede, disco, Docker próprios), sem regras `DOCKER-USER`, sem choque de porta 8000 entre Supabase e SurrealDB, backup via `lxc snapshot`/`export`.
- SurrealDB **v3.3.0** por digest, RocksDB, `user 10001`, `mem_limit 2g`, `cpus 1`.
- Um **namespace por projeto**, databases por ambiente, usuário OWNER por database. Senhas no cofre (Vaultwarden).
- Acesso só pela `lxdbr0` (IP do LXC); dentro do LXC o compose publica a porta no IP do `eth0`.
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

- `docker/docker-compose.yml`, `.env.example`, `scripts/init_surreal.sh` (idempotente; `--rotate [projeto]`), `scripts/oute-assessment.sh`, `docs/plano.html`.
- `scripts/firewall_surreal.sh` + `systemd/oute-surreal-firewall.service`: do desenho anterior (Docker no host). **Saem** quando o compose for ajustado para o LXC.
- **Pendente**: compose/.env ainda refletem o desenho anterior (bind em `10.173.117.1`, bridge nomeada). Ajuste após as decisões abaixo.

## Perguntas abertas

1. Central SurrealDB só para kubo+obo vale, ou cada um segue com o seu embutido (só padronizando versão)?
2. hanko é o teamhanko (passkeys) ou app próprio? Se teamhanko, Supabase Auth pode substituí-lo.
3. Repo oute-supabase-db: reset para só `docker/` + nossos arquivos, ou sparse-checkout do fork?
4. Nome das databases: `prd`/`test` (espelha LXCs) ou `prod`/`dev`?
5. Usuário read-only por database (kubo usa `kubo_ro`): criar?
6. Pilotos: kubo-test (surreal) e financial-control (supabase)?

## Fases

1. **Preparação** (esta branch): assessments, divisão, decisões, docs. ✔ (falta ajustar compose p/ LXC)
2. **LXC oute-surreal-db**: `lxc launch` (perfil padrão, Docker dentro), repo em `/opt/oute-surreal-db`, `.env` 600, `compose up`, `init_surreal.sh`, senhas no cofre. Verificar: healthy; de kubo-test `curl http://<ip>:8000/health` ok; do host Docker nada chega além da lxdbr0.
3. **Piloto kubo-test** → kubo-prd: export/import, apontar app, validar, rollback definido.
4. **obo**: export v2 → import v3, rodada de testes do app.
5. **oute-supabase-db**: repo + LXC + pilotos (financial-control → frentes → hanko). Plano próprio naquele repo.
6. **Backup**: política de snapshots LXC.
