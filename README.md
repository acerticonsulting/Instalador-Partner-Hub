# Instalador Amanda Partner Hub

Instalador local, derivado do modelo `Instalador-AMANDA`, para publicar o Amanda
Partner Hub em uma VPS Linux (incluindo Contabo) com Docker Compose, Caddy e um
projeto Supabase Free externo.

Ele não instala PostgreSQL, não executa SQL/migrations, não chama a API do
Supabase e não remove volumes, imagens, stacks ou backups. A stack contém apenas:

```text
Internet :80/:443 -> Caddy -> app TanStack Start/Nitro :3000 -> Supabase Free externo
```

## Pré-requisitos

- VPS Linux com Docker Engine e Docker Compose v2;
- Git;
- DNS A/AAAA do domínio apontando para a VPS;
- portas TCP 80/443 e UDP 443 liberadas;
- projeto Supabase Free já preparado pelo proprietário, sem migrations pelo instalador;
- acesso de leitura ao repositório da aplicação;
- um ref Git revisado (preferencialmente commit ou tag imutável).

Execute primeiro:

```sh
sh partner-hub.sh doctor
```

## Preparar o ambiente privado

O template não contém credenciais reais:

```sh
install -d -m 700 "$HOME/.config/amanda-partner-hub"
install -m 600 templates/runtime.env.example "$HOME/.config/amanda-partner-hub/runtime.env"
editor "$HOME/.config/amanda-partner-hub/runtime.env"
sh partner-hub.sh validate --env "$HOME/.config/amanda-partner-hub/runtime.env"
```

Use somente as chaves do Supabase Free destinado ao Partner Hub. A service role é
segredo de runtime e nunca entra no build; URL e publishable key `VITE_*` são
públicas e entram no bundle do navegador. Microsoft e Clicksign permanecem
desabilitados por padrão.

## Validar sem instalar

O dry-run não cria diretórios, não chama Git/Docker e não altera containers:

```sh
sh partner-hub.sh install \
  --dir /opt/amanda-partner-hub \
  --env "$HOME/.config/amanda-partner-hub/runtime.env" \
  --ref <commit-aprovado> \
  --dry-run
```

## Instalação inicial

```sh
sudo sh partner-hub.sh install \
  --dir /opt/amanda-partner-hub \
  --env "$HOME/.config/amanda-partner-hub/runtime.env" \
  --ref <commit-aprovado>
```

Sem `--yes`, o instalador pede a confirmação literal `SIM` somente depois do
clone, validação do Compose e build. Ele recusa um diretório já existente. Uma
falha antes da saúde final mantém estado `prepared`; corrija a causa e use:

```sh
sudo sh partner-hub.sh resume --dir /opt/amanda-partner-hub
```

## Operação

```sh
sudo sh partner-hub.sh status --dir /opt/amanda-partner-hub
sudo sh partner-hub.sh logs --dir /opt/amanda-partner-hub
sudo sh partner-hub.sh stop --dir /opt/amanda-partner-hub
sudo sh partner-hub.sh start --dir /opt/amanda-partner-hub
```

`stop` usa apenas `docker compose stop`: certificados e demais volumes ficam
preservados. Os logs são limitados às últimas 200 linhas; ainda assim, trate-os
como dados privados.

## Atualização e recuperação

Atualizações exigem ref explícito e checkout limpo. A nova imagem é construída
antes da troca. Não há migrations nem alterações no Supabase.

```sh
sudo sh partner-hub.sh update \
  --dir /opt/amanda-partner-hub \
  --ref <novo-commit-aprovado>
```

A imagem anterior permanece registrada. Se a nova aplicação não ficar saudável,
o instalador tenta reativar a imagem anterior. Um rollback manual troca somente a
imagem da aplicação e não modifica banco externo:

```sh
sudo sh partner-hub.sh rollback --dir /opt/amanda-partner-hub
```

Rollback de imagem não corrige incompatibilidade de schema. Se uma versão exigir
migration, interrompa a publicação e siga o processo manual aprovado do projeto.

## Estrutura criada na VPS

```text
/opt/amanda-partner-hub/
  source/              checkout Git da aplicação
  deploy/              Dockerfile, Compose e Caddyfile gerenciados
  private/             runtime.env, state.env e lock (modo restrito)
```

Os certificados ficam nos volumes nomeados `caddy_data` e `caddy_config`. Dados
de negócio, autenticação e storage continuam no Supabase externo. Copie o arquivo
privado de ambiente para backup seguro fora do checkout; nunca o versione.

## Validação de desenvolvimento

```sh
bash tests/validate.sh
```

A suíte é estática e usa somente dry-run. Ela não inicia containers e não toca em
stacks existentes.
