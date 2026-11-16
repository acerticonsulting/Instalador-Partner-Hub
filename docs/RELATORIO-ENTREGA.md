# Relatório de entrega — 16/11/2026

## 1. Localização do instalador original

`C:\Users\GustavoFranzotiGonça\Desktop\Desenvolvimento Partner Plataform\Instalador-AMANDA`

Foi escolhido o fluxo Docker-only atual. Os scripts em `legacy/` foram comparados
conceitualmente e descartados por dependerem de instalação nativa, PM2, Nginx e
banco no host.

## 2. Arquitetura identificada

O original usa uma entrada POSIX shell que constrói e executa um gerenciador
CommonJS/Node em container. O gerenciador controla Docker Compose, Git, ambientes,
estado, locks, backups, migrations, seeds, health checks, atualizações e retomada.
Ele foi criado para a plataforma AMANDA omnichannel, composta por frontend,
backend, PostgreSQL, Redis, RabbitMQ, transcrição, API Oficial, WuzAPI e Caddy.

O Partner Hub real é uma aplicação TanStack Start/React/Nitro única. O build usa
Bun e produz `.output/server/index.mjs`, executado em Node 22. Banco, Auth e
Storage pertencem ao Supabase externo; não existe banco local nesta adaptação.

## 3. Arquivos/padrões reutilizados

- `Instalador-AMANDA/instalador_single.sh`: entrada POSIX, proteção de caminhos,
  diagnóstico Docker e comandos separados;
- `docker/installer/manager.cjs`: estado, lock, build antes da troca, retomada,
  imagem anterior e health checks;
- `docker/installer/options.cjs`: leitura controlada de ambiente, validação e
  permissões restritas;
- `docker/installer/Dockerfile`: ferramentas/build isolados por container;
- `tests/validar_instalador.sh` e regressões: abordagem de testes sem instalação;
- Dockerfile, Compose, Caddyfile e documentação de deploy já presentes no
  worktree do `partners-amanda`, apenas como referência de arquitetura.

Nenhum arquivo original foi modificado.

## 4. Arquivos adaptados

- `partner-hub.sh`: instalação, validação, dry-run, retomada, atualização,
  status, logs, start/stop e rollback sem migrations;
- `templates/compose.yaml`: apenas `app + caddy`;
- `templates/Dockerfile`: build Bun 1.4.4 e runtime Node 22;
- `templates/Caddyfile`: HTTPS e proxy reverso;
- `templates/runtime.env.example`: placeholders, sem credenciais;
- `tests/validate.sh`: regressões locais seguras;
- `README.md`, `docs/ADAPTACAO.md` e este relatório.

## 5. Caminho do novo instalador

`C:\Users\GustavoFranzotiGonça\Desktop\Desenvolvimento Partner Plataform\Instalador-Partner-Hub`

## 6. Instalação e atualização

Resumo; os comandos completos estão no `README.md`.

```sh
sh partner-hub.sh doctor
sh partner-hub.sh validate --env /caminho/privado/runtime.env
sh partner-hub.sh install --dir /opt/amanda-partner-hub \
  --env /caminho/privado/runtime.env --ref <commit-aprovado> --dry-run
sudo sh partner-hub.sh install --dir /opt/amanda-partner-hub \
  --env /caminho/privado/runtime.env --ref <commit-aprovado>
sudo sh partner-hub.sh update --dir /opt/amanda-partner-hub \
  --ref <novo-commit-aprovado>
```

O instalador recusa sobrescrever destino existente. Uma instalação interrompida
após registrar o estado usa `resume`; instalação saudável usa `update`. Toda troca
real pede `SIM` ou `--yes`. Nenhum comando `down`, prune, reset ou exclusão de
volume foi implementado.

## 7. Resultado dos testes

- `sh -n`: aprovado;
- presença dos templates: aprovado;
- ambiente válido e variáveis obrigatórias: aprovado;
- domínio inválido: recusado;
- dry-run repetido: aprovado, sem escrita e sem Git/Docker;
- busca por prune/down/rm/db reset/migrations no instalador: limpa;
- busca de padrões de credenciais reais: limpa;
- health checks: presentes;
- suíte `tests/validate.sh`: 11/11 aprovada;
- `docker compose config --quiet`: aprovado com valores fictícios;
- containers iniciados/alterados: zero;
- migrations executadas: zero;
- acesso a Supabase/VPS/rede de deploy: zero.

## 8. Dependências pendentes

- commit ou tag aprovado contendo a versão implantável do `partners-amanda`;
- `bun.lock` sincronizado nesse ref para `bun install --frozen-lockfile`;
- domínio definitivo e DNS apontando para a Contabo;
- portas 80/443 TCP e 443 UDP liberadas;
- Docker Engine, Compose v2 e Git na VPS;
- arquivo privado com as credenciais do projeto Supabase Free correto;
- schema/dados do Supabase Free preparados manualmente pelo proprietário;
- decisão e credenciais separadas para Microsoft/Clicksign, se forem habilitados.

## 9. Riscos

- O worktree local do `partners-amanda` está à frente de `origin/develop` e tem
  muitas mudanças não commitadas. Dockerfile, Compose, Caddyfile e documentação
  também estão não rastreados. Um clone na VPS não receberá esse estado local.
- O plano Supabase (Free ou Pro) não é inferível pela URL. A conferência humana do
  projeto é obrigatória para impedir uso do Pro.
- Não houve build real da imagem nem smoke test HTTPS, pois isso exigiria artefato
  Git aprovado/DNS e fugiria da validação local sem containers solicitada.
- Caddy só emitirá certificado com DNS propagado e portas públicas acessíveis.
- Rollback troca a imagem, mas nunca reverte schema externo.
- Webhooks e execução pós-resposta precisam de teste em homologação Node real.

## 10. Próxima ação recomendada

Consolidar e revisar as mudanças atuais do `partners-amanda`, executar a suíte da
aplicação, gerar um commit/tag imutável aprovado com `bun.lock` sincronizado e
disponibilizá-lo no repositório acessível pela VPS. Depois, na Contabo, preencher
o ambiente privado com o Supabase Free, executar `doctor`, `validate` e o dry-run;
só então autorizar a instalação real. Não aplicar migrations nessa etapa.
