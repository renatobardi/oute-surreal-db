# Projeto: Consolidização do SurrealDB

## Histórico resumido

1. **Inventário inicial**
   - Listamos todos os containers LXC/LXD que estavam rodando no VPS (`oute‑server`).
   - Identificamos o container Docker do SurrealDB (`b88aee607449`) que já estava ativo sob o nome **`oute-surrealdb`**.
   - O usuário solicitou a consolidação de múltiplos projetos (studio, obo, kubo, oute‑agent, hanko, frentes‑engenharia, financial‑control, vaultgarden) em uma única instância SurrealDB.

2. **Requisitos e decisões**
   - Utilizar **um único container Docker** chamado **`oute‑surreal‑db`** (renomeado a partir de `oute‑surrealdb`).
   - Persistência usando **RocksDB** no diretório host **`/srv/oute-db`**.
   - Porta padrão **8000**, mas validar a disponibilidade.
   - Cada projeto terá **namespace** próprio e **databases** `dev` e `prod`.
   - **Token por database** (dev / prod) com permissões completas; todos os segredos são armazenados no VaultGarden, nunca no repositório.
   - Backup semanal, retenção de **2 dumps (≈ 15 dias)**.
   - Firewall restrito à rede interna da bridge LXD (`lxdbr0`).

3. **Script de assessment**
   - Foi criado o script `oute-assessment.sh` (no Mac) que, via SSH, executa no host Linux:
     - `lsblk` e `df -hT` para identificar discos e montar `/srv/oute-db`.
     - Verifica se a porta 8000 está livre.
     - Obtém o IP da bridge `lxdbr0`.
     - Checa a existência do diretório de dados.
   - O script grava um relatório em `/tmp/oute_assessment.txt` no servidor.

4. **Arquivos planejados** (já descritos na conversa)
   - `docker/docker-compose.yml` – define o serviço `oute-surreal-db` com volume, porta e variáveis de ambiente.
   - `surreal/init.surrealql` – cria namespaces, databases, scopes e tokens.
   - Exemplos de conexão para **SvelteKit (TypeScript)** e **Rust** que leem os tokens via variáveis de ambiente.
   - `scripts/backup_surreal.sh` – exporta cada namespace/database semanalmente e mantém apenas os dois últimos dumps.
   - `scripts/firewall_surreal.sh` – regras iptables que permitem acesso apenas da rede LXD.
   - `README.md` (atualizado) com instruções de implantação.

5. **Resultado do assessment (2026-10-18)**
   - Host: Ubuntu 24.04 (aarch64, Oracle Cloud), 4 vCPU, 23 GiB RAM.
   - `/srv` fica no disco raiz (`/dev/sda1`, 17 GiB livres). `/mnt/lxd` (`/dev/sdb`, 115 GiB livres) é o disco do pool LXD.
   - O `oute-surrealdb` já roda (v3.3.0, RocksDB, `unless-stopped`, healthy) com dados em `/mnt/lxd/oute-data/surrealdb`. O diretório `/srv/oute-db` não existe.
   - O container não publica portas (só redes Docker). A porta 8000 está livre no host.
   - `lxdbr0` = `10.173.117.1/24`. Os containers LXC (studio, obo, kubo, hanko, frentes-engenharia, financial-control, vaultwarden) estão em `10.173.117.x`.
   - O usuário `ubuntu` não tem sudo sem senha: `nft`/`iptables` não puderam ser lidos.
   - Não há crontab. Os agendamentos usam systemd timers (ex.: `oute-studio-backup.timer`).
   - `rc-local.service` está com falha (não relacionado a este projeto).

6. **Decisões revisadas (propostas, a confirmar)**
   - Reusar `/mnt/lxd/oute-data/surrealdb` no lugar de `/srv/oute-db`: evita migrar dados e tem mais espaço.
   - Publicar a porta 8000 apenas em `10.173.117.1` (IP da `lxdbr0`). Isso substitui o script de firewall dedicado; ele só volta se quisermos regras adicionais.
   - Backup semanal via systemd timer (padrão já usado no servidor), e não via cron.
   - Antes de renomear para `oute-surreal-db`, descobrir quem depende do nome `oute-surrealdb` (provável stack `oute-agent`). Se necessário, manter o nome antigo como alias de rede.

7. **Arquivos criados (nada foi implantado ainda)**
   - `docker/docker-compose.yml`, `.env.example`
   - `scripts/init_surreal.sh` (namespaces, databases dev/prod e um usuário por database; substitui o `init.surrealql`)
   - `scripts/backup_surreal.sh` + `systemd/oute-surreal-backup.{service,timer}` (semanal, mantém 2 dumps)

8. **Próximos passos (no servidor, nesta ordem)**
   - Rodar o assessment de novo para descobrir quem depende de `oute-surrealdb` (redes, aliases, labels).
   - Copiar o repo para `/opt/oute-surreal-db`, criar o `.env` a partir do `.env.example` e preencher `SURREAL_ROOT_PASS`.
   - Fazer cópia do diretório de dados, parar o container antigo (RocksDB aceita um processo por diretório) e subir o novo.
   - Rodar `init_surreal.sh` e guardar as senhas no VaultGarden.
   - Instalar o service/timer do backup.

---

Esta documentação será usada como ponto de partida para os próximos *harnesses* quando necessário.  
Qualquer alteração ou continuação do processo pode ser feita editando este arquivo ou adicionando novos artefatos ao repositório.
