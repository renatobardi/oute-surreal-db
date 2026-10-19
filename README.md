# oute-surreal-db

SurrealDB **central e isolado** dos projetos Oute, rodando em um LXC próprio no `oute-server`.
Um namespace por projeto, databases `prd`/`test`, dois usuários por database. Novos projetos entram como namespace.

**Este repositório é a fonte da verdade** do banco: decisões, topologia, convenções, scripts e runbooks.
Se algo no servidor diverge do que está aqui, o servidor está errado (ou este repo precisa de um PR).

| Preciso de… | Vá para |
|---|---|
| Entender o desenho e por que ele é assim | [`docs/DESIGN.md`](docs/DESIGN.md) |
| Operar (conectar app, adicionar projeto/cliente, rotacionar senha, snapshot, upgrade, migrar) | [`docs/OPERATIONS.md`](docs/OPERATIONS.md) |
| Visão geral com diagrama e fases | [`docs/plano.html`](docs/plano.html) |
| Estado atual / memória entre sessões | [`SUMMARY.md`](SUMMARY.md) |

## Estrutura

| Caminho | Papel |
|---|---|
| `docker/docker-compose.yml` | Serviço SurrealDB (roda **dentro** do LXC) |
| `.env.example` | Variáveis; o `.env` real vive só no LXC (600, nunca no git) |
| `scripts/init_surreal.sh` | Cria namespaces/databases/usuários (idempotente, `--rotate`). Roda **dentro** do LXC |
| `scripts/oute-assessment.sh` | Inventário read-only do servidor via SSH (relatórios em `reports/`, ignorado) |
| `ops/provision_lxc.sh` | Roda **no Mac**: cria/atualiza o LXC, firewall, Docker, repo, compose, init e **verifica o isolamento**. `--check` só confere pré-condições |
| `ops/rotate_and_show_credentials.sh` | Roda **no Mac**: gera senhas novas e mostra tudo no seu terminal |

## Em uma linha

`ws://10.173.117.50:8000/rpc` · SurrealDB v3.3.0 · só kubo-prd, kubo-test e obo-prd alcançam · senhas no Vaultwarden.
