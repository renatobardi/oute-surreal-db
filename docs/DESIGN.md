# Desenho

## Objetivo
Um SurrealDB único, isolado e padronizado para os projetos Oute que realmente precisam dele, em vez de cada projeto
carregar o seu embutido (versões diferentes, backup diferente, senha root na linha de comando). Novos projetos
entram como namespace, sem novo container.

## Escopo

| Projeto | Situação | Motivo |
|---|---|---|
| **kubo** (prd, test) | **dentro** | Grafo (`RELATE`/travessias), vetores HNSW, SCHEMAFULL, live queries: o caso que justifica SurrealDB |
| **obo** (prd) | **dentro** | FTS (`search::`), vetores, `DEFINE FUNCTION`. Empate técnico com Postgres; fica por custo de reescrita |
| hanko, frentes-engenharia, financial-control | fora → [oute-supabase-db](https://github.com/renatobardi/oute-supabase-db) | Relacionais (Postgres/SQLite) |
| oute-agent | fora | SurrealDB próprio por decisão do ADR-08 do oute-agent (dado derivado, isolado do agente yolo). Revisão só via ADR |
| vaultwarden | fora (SQLite) | Cofre isolado de propósito: não pode depender de um stack cujas senhas ele guarda |
| studio | fora | Descontinuado |

Critério de entrada: o app usa de fato recursos que SurrealDB faz bem (grafo, vetor, FTS, live query). Não entra "porque já está lá".

## Topologia

- **LXC `oute-surreal-db`** no `oute-server` (Ubuntu 24.04 aarch64, LXD 5.21, pool `oute-pool` em `/mnt/lxd`), na `lxdbr0` (`10.173.117.0/24`).
- Padrão da casa: todo projeto é um LXC com Docker dentro. Config do LXC: IP fixo `10.173.117.50`, 2 CPU, 3 GiB, `security.nesting=true`, `boot.autostart=true`, `snapshots.expiry=7d`.
- Dentro do LXC: `docker.io` + compose v2 (`dns 1.1.1.1`), repo em `/opt/oute-surreal-db`, dados em `/srv/oute-surreal-db/data` (dono `10001:10001`).
- Container `oute-surreal-db`: SurrealDB **v3.3.0 fixado por digest**, RocksDB, `user 10001`, `mem_limit 2g`, `cpus 1`, porta `8000`, healthcheck `surreal is-ready`.
- Nada é compartilhado com outro stack: rede, disco, Docker e container próprios. O `oute-surrealdb` do oute-agent não é tocado.

## Isolamento de rede

Medido em 2026-10-18: **containers Docker do host — inclusive a rede do agente yolo — alcançam IPs de LXC.** LXC sozinho não isola do host.

- ACL do LXD não serve: o LXD 5.21 rejeita `security.acls` em NIC de bridge.
- Barreira adotada: **firewall nft dentro do LXC** (tabela própria `inet oute_sdb`, hook `forward`, prioridade -10). Só os IPs dos LXCs clientes chegam na 8000; o resto é derrubado. Não mexe nas regras do Docker.
- O tráfego dos containers Docker do host chega mascarado como `10.173.117.1` (IP da lxdbr0), fora da lista.
- Persistido em `/etc/nftables.conf` (`nftables.service`); sobrevive a reboot do LXC (testado).
- `ops/provision_lxc.sh` testa o negativo a cada execução: kubo-test alcança; vaultwarden e containers Docker do host (`bridge`, `oute-agent_oute`) são bloqueados. Falha com exit 2 se algo vazar.
- Sem sudo no host: tudo roda como `ubuntu` via `lxc`.

Clientes autorizados hoje: `10.173.117.21` (kubo-prd), `10.173.117.18` (kubo-test), `10.173.117.30` (obo-prd).

## Modelo de dados e acesso

| Dimensão | Convenção |
|---|---|
| Namespace | nome do projeto; hífen vira underscore (`oute-agent` → `oute_agent`) |
| Database | `prd` e `test` (espelha os sufixos dos LXCs). **Só se cria o que existe** (obo não tem `test`) |
| Usuários | por database: `app_<db>` **OWNER** (a aplicação) e `ro_<db>` **VIEWER** (backup, leitura, agentes que só leem). `root` só para ops |
| Nível de auth | usuários são **de database**: no CLI use `--auth-level database`; nos SDKs, signin com namespace + database + usuário |
| Cofre (Vaultwarden) | `oute-surreal-db/root` e `oute-surreal-db/<ns>/<db>/<usuário>` |
| Env vars nos apps | padrão a adotar na migração de cada app: `SURREAL_URL`, `SURREAL_NS`, `SURREAL_DB`, `SURREAL_USER`, `SURREAL_PASS` (hoje divergem: `NAMESPACE`/`DATABASE`/`PASSWORD` no obo) |
| Endpoint | `ws://10.173.117.50:8000/rpc` (SDK) · `http://10.173.117.50:8000/health` |
| Senha root | nunca em argumento de linha de comando (kubo/obo fazem hoje; `docker inspect` expõe). Aqui vai por env no `.env` (600) |

## Decisões (2026-10-18)

1. **Central**, não embutido por projeto — é o propósito do repo; novos projetos viram namespace.
2. **LXC por stack**, não Docker no host: isolamento por construção, sem choque de porta com o Supabase, backup por `lxc snapshot`.
3. **`prd`/`test`**, criados só onde o ambiente existe.
4. **Dois usuários por database** (OWNER + VIEWER): menor privilégio, e o kubo já depende de um usuário read-only.
5. **Backup adiado**: `/mnt/lxd` não tem backup OCI. Hoje só snapshot manual/7 dias. Política na fase F6.
6. **Pilotos**: kubo-test → kubo-prd → obo (surreal); financial-control → frentes-engenharia → hanko (supabase).
7. **Repo próprio, sem amarra ao upstream** (vale para o oute-supabase-db, que deixou de ser fork do monorepo).

## Fases

| Fase | Estado |
|---|---|
| F1 Preparação (assessments, desenho, docs) | feito |
| F2 LXC + instância + isolamento | feito 2026-10-18 (snapshot `pos-f2`) |
| F3 Piloto kubo-test → kubo-prd | próxima |
| F4 obo (v2 → v3, exige teste do app) | |
| F5 oute-supabase-db | repo próprio |
| F6 Backup | a definir |

## Riscos conhecidos

| Risco | Mitigação |
|---|---|
| obo está em SurrealDB 2.6.5; v3 tem breaking changes de SurrealQL | Export/import + rodada de testes do app antes de apontar prd; origem fica viva |
| Vários projetos num processo | Namespaces e usuários separados, limites de CPU/RAM; decisão consciente |
| RocksDB sem limite consome a RAM | `mem_limit 2g` |
| Re-executar init trocaria senhas | Init idempotente; rotação só com `--rotate` |
| Allowlist de IPs exige manutenção | Ver runbook "Adicionar projeto cliente" |
| Sem backup real até a F6 | Snapshot manual antes de cada migração; snapshots expiram em 7 dias |
