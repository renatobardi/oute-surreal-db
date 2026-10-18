# Projeto: SurrealDB isolado para os projetos Oute

## Decisões (2026-10-18)

- **Instância nova e isolada.** Container `oute-surreal-db`, rede Docker própria (`oute-surreal-db`, bridge `br-oute-sdb`), dir de dados próprio `/mnt/lxd/oute-surreal-db`. Não compartilha nada com outra stack.
- **O `oute-surrealdb` do oute-agent fica intocado.** É o serviço `surrealdb` do compose `/home/ubuntu/oute-agent` (profile `agent-studio`, ADR-08). Seu conteúdo será migrado para cá em fase posterior.
- Um **namespace por projeto**, databases `dev` e `prod`, usuário OWNER `app_dev`/`app_prod` por database. Senhas no cofre.
- Acesso só pela rede LXD: porta publicada em `10.173.117.1:8000` **e** firewall em `DOCKER-USER` (só origem `10.173.117.0/24`; container sem saída). Sem o firewall, qualquer container Docker do host alcançaria o banco.
- Roda como `10001:10001` (uid da imagem), `mem_limit 2g`, `cpus 1` (RocksDB sem limite usa ~metade da RAM do host).
- **Backup: adiado.** `/mnt/lxd` não tem backup OCI. Decidir depois.
- **Migração piloto: kubo e obo.** Demais depois.

## Assessment do servidor (2026-10-18, `scripts/oute-assessment.sh`)

- Ubuntu 24.04 aarch64 (Oracle), 4 vCPU, 23 GiB RAM, sem swap. Docker 29.1.3, Compose 2.40.3, `ubuntu` usa docker sem sudo; **sudo exige senha**.
- `/` (sda1) 17 GiB livres; `/mnt/lxd` (sdb) 115 GiB livres, pool LXD `oute-pool`.
- Porta 8000 livre no host. `lxdbr0` = `10.173.117.1/24`; LXCs: studio-prd/test, obo-prd, kubo-prd/test, hanko-prd, frentes-engenharia-prd, financial-control-prd, vaultwarden, uptime-kuma.
- `oute-surrealdb` existente: v3.3.0 por digest, user 10001, mem 2g, sem porta publicada, rede `oute-agent_studio`, aliases `surrealdb`/`oute-surrealdb`, dados em `/mnt/lxd/oute-data/surrealdb` (109 MB). Log avisa que o root já existia (senha do .env do oute-agent pode não ser a real).
- Agendamentos do host usam systemd timers; não há crontab.

## Arquivos

- `docker/docker-compose.yml`, `.env.example`
- `scripts/init_surreal.sh` — ns/db/usuários; idempotente; `--rotate [projeto]` para senhas novas
- `scripts/firewall_surreal.sh` + `systemd/oute-surreal-firewall.service` — isolamento de rede, persistente
- `scripts/oute-assessment.sh` — inventário read-only via SSH (relatórios em `reports/`, ignorado)
- `docs/plano.html` — plano autocontido (escopo, decisões, fases)

## Perguntas abertas

- **vaultgarden**: o LXC do servidor é `vaultwarden` (Bitwarden-compatível, usa SQLite/Postgres — não usa SurrealDB). Se "vaultgarden" for esse, sai da lista. Se for projeto próprio, fica.
- Senha root do `oute-surrealdb` (oute-agent) precisa ser validada antes da migração do conteúdo dele.
- Onde kubo e obo guardam dados hoje (dentro dos LXCs?) — define o método de export na fase piloto.

## Fases

1. **Preparação** (esta branch): arquivos acima. ✔
2. **Deploy da instância**: copiar repo para `/opt/oute-surreal-db`, `.env` (600), criar `/mnt/lxd/oute-surreal-db` como 10001:10001, `compose up`, firewall + service, `init_surreal.sh`, senhas no cofre. Verificar: healthy; LXC alcança 10.173.117.1:8000; container do oute-agent **não** alcança.
3. **Piloto kubo + obo**: export na origem → import em `kubo/prod`, `obo/prod`; apontar app; validar; rollback = voltar a URL antiga.
4. **Demais projetos**: studio, hanko, frentes-engenharia, financial-control, oute-agent, vaultgarden (se confirmado).
5. **Backup**: a definir.
