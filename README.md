# oute-surreal-db

SurrealDB isolado para os projetos Oute no `oute-server`: um container, rede e disco próprios,
um namespace por projeto (`dev`/`prod`), acesso só pela rede LXD.

- Plano, decisões e fases: `SUMMARY.md` e `docs/plano.html`
- Assessment do servidor (read-only): `./scripts/oute-assessment.sh`
