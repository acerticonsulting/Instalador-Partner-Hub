# Registro de descoberta e adaptação

## Origem analisada

- Instalador: `../Instalador-AMANDA` no workspace pai.
- Entrada oficial: `instalador_single.sh` (POSIX shell).
- Gerenciador: CommonJS/Node em `docker/installer/*.cjs`, executado em container.
- Aplicação original: AMANDA de atendimento multicanal, repositório
  `acerticonsulting/AMANDA`, com frontend, backend, PostgreSQL, Redis,
  transcrição, API Oficial, WuzAPI e RabbitMQ; Caddy é opcional.
- Fluxo original: valida Docker local, constrói a imagem do gerenciador, clona a
  aplicação, gera ambientes, constrói Compose, executa migrations/seeds na
  instalação inicial, verifica saúde/login e mantém estado, backups, retomada,
  atualização e restauração.
- `legacy/` contém instaladores antigos com PM2/Nginx/banco no host e não foi
  escolhido, pois o fluxo Docker-only atual é mais isolado e testável.

## Aplicação de destino

`partners-amanda` é uma aplicação única TanStack Start + React 19 + Nitro/Vite,
construída com Bun e executada pelo Node 22 a partir de
`.output/server/index.mjs`. O banco, Auth e Storage são externos no Supabase. O
repositório local já contém um Dockerfile/Compose/Caddyfile em desenvolvimento,
mas estavam não rastreados ou modificados durante a descoberta; foram apenas
lidos e não alterados.

## Decisão de adaptação

Reutilizado:

- entrada POSIX shell e host com poucos pré-requisitos;
- validação de caminhos protegidos e Docker Linux;
- estado privado com modo restrito;
- lock por instalação;
- instalação, retomada, atualização e operação separadas;
- build antes da troca, imagem anterior preservada e health check;
- Caddy em container com certificados persistentes;
- recusa a checkout sujo e a instalações já existentes.

Modificado:

- stack reduzida para `app + caddy`;
- um único domínio e uma única aplicação Nitro;
- build multi-stage Bun/Node;
- variáveis públicas do Supabase no build e secrets somente no runtime;
- atualização sem migration, seed ou banco local;
- ambiente operacional fornecido por arquivo externo e copiado com modo 600;
- integrações Microsoft/Clicksign desabilitadas por padrão.

Removido:

- PostgreSQL, Redis, RabbitMQ, PgBouncer e seus backups/restores;
- migrations Sequelize/Prisma, seeds e criação de administrador;
- API Oficial, WuzAPI, WhatsMeow, Baileys, transcrição, VOZ/HUB e addons;
- Portainer, agendadores, importação SQL e desinstalação;
- qualquer opção que remova containers, volumes, imagens ou diretórios.

## Limites deliberados

- O plano Free do Supabase não pode ser comprovado apenas pela URL; a seleção do
  projeto correto depende da conferência humana do arquivo privado.
- O instalador não prepara schema nem dados e não valida compatibilidade do banco.
- DNS, firewall, credenciais reais, acesso à VPS e deploy remoto permanecem fora
  desta entrega.
- O primeiro build real depende de `bun.lock` estar sincronizado no ref escolhido.
- Webhooks e trabalhos pós-resposta no preset Node precisam de homologação real.
