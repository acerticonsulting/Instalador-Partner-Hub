#!/bin/sh
set -eu

PROGRAM=${0##*/}
case "$0" in */*) SCRIPT_DIR=${0%/*} ;; *) SCRIPT_DIR=. ;; esac
SCRIPT_DIR=$(CDPATH= cd -P "$SCRIPT_DIR" && pwd)

DEFAULT_SOURCE_URL=https://github.com/acerticonsulting/partners-amanda.git
FREE_HML_SUPABASE_HOST=aexvrietkksxlxzztsua.supabase.co
TARGET=${PARTNER_HUB_INSTALL_DIR:-/opt/amanda-partner-hub}
ENV_INPUT=
REF=
SOURCE_URL=$DEFAULT_SOURCE_URL
ACTION=help
DRY_RUN=false
ASSUME_YES=false

usage() {
  cat <<'EOF'
Amanda Partner Hub - instalador Docker seguro

Uso:
  sh partner-hub.sh doctor
  sh partner-hub.sh validate --env /caminho/runtime.env
  sh partner-hub.sh install --dir /opt/amanda-partner-hub --env /caminho/runtime.env --ref <branch|tag|commit> [--yes]
  sh partner-hub.sh resume --dir /opt/amanda-partner-hub [--yes]
  sh partner-hub.sh update --dir /opt/amanda-partner-hub --ref <branch|tag|commit> [--yes]
  sh partner-hub.sh status|logs|start|stop --dir /opt/amanda-partner-hub
  sh partner-hub.sh rollback --dir /opt/amanda-partner-hub [--yes]

Opcoes:
  --source URL   Repositorio Git (padrao: repositorio oficial partners-amanda)
  --dry-run      Valida e mostra as etapas, sem escrever arquivos ou chamar Docker/Git
  --yes          Confirma a troca/inicializacao de containers

O instalador nunca aplica migrations, nunca acessa Supabase via API e nunca remove
volumes, imagens, backups ou stacks. Use um projeto Supabase Free exclusivo.
EOF
}

die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    help|-h|--help) ACTION=help; shift ;;
    doctor|validate|install|resume|update|status|logs|start|stop|rollback) ACTION=$1; shift ;;
    --dir) [ "$#" -ge 2 ] || die 'Falta o valor de --dir.'; TARGET=$2; shift 2 ;;
    --env) [ "$#" -ge 2 ] || die 'Falta o valor de --env.'; ENV_INPUT=$2; shift 2 ;;
    --ref) [ "$#" -ge 2 ] || die 'Falta o valor de --ref.'; REF=$2; shift 2 ;;
    --source) [ "$#" -ge 2 ] || die 'Falta o valor de --source.'; SOURCE_URL=$2; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    *) die "Argumento nao suportado: $1" ;;
  esac
done

case "$TARGET" in
  /*) ;;
  *) TARGET=$PWD/$TARGET ;;
esac

case "$SOURCE_URL" in
  https://*/*) ;;
  *) die 'A origem Git deve usar URL HTTPS.' ;;
esac
case "$SOURCE_URL" in *'@'*|*'?'*|*'#'*|*'
'*) die 'URL Git com credencial, query, fragmento ou quebra de linha foi recusada.' ;; esac
if [ -n "$REF" ]; then
  case "$REF" in -*|*..*|*[!A-Za-z0-9._/-]*|*'
'*) die 'Ref Git invalido.' ;; esac
fi
case "$TARGET" in
  /|/etc|/usr|/bin|/sbin|/dev|/proc|/sys|/run|/var/lib/docker) die 'Escolha um diretorio exclusivo para o Partner Hub.' ;;
  /etc/*|/usr/*|/bin/*|/sbin/*|/dev/*|/proc/*|/sys/*|/run/*|/var/lib/docker/*|*/../*|*/..) die 'Diretorio protegido ou caminho nao suportado.' ;;
esac

SOURCE_DIR=$TARGET/source
DEPLOY_DIR=$TARGET/deploy
PRIVATE_DIR=$TARGET/private
STATE_FILE=$PRIVATE_DIR/state.env
RUNTIME_ENV=$PRIVATE_DIR/runtime.env
LOCK_DIR=$PRIVATE_DIR/operation.lock

env_value() {
  key=$1 file=$2
  awk -v key="$key" 'index($0,key "=")==1 { print substr($0,length(key)+2); found=1; exit } END { if(!found) exit 1 }' "$file"
}

state_value() { env_value "$1" "$STATE_FILE"; }

credential_is_placeholder() {
  normalized=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$normalized" in
    replace-*|replace_*|*placeholder*|change-me|change_me|changeme|todo|tbd|xxx|xxx*|your-*-key|your_*-key|your-*-token|your_*-token|your-*-secret|your_*-secret|public-key-for-*-only|\<*\>) return 0 ;;
    *) return 1 ;;
  esac
}

validate_env() {
  file=$1
  [ -f "$file" ] || die "Arquivo de ambiente nao encontrado: $file"
  [ ! -L "$file" ] || die 'Arquivo de ambiente nao pode ser link simbolico.'
  bad=$(awk '
    index($0,"\r") { print NR; exit }
    /^[[:space:]]*($|#)/ { next }
    !/^[A-Z_][A-Z0-9_]*=/ { print NR; exit }
    { key=$0; sub(/=.*/,"",key); if(seen[key]++) { print NR; exit } }
  ' "$file")
  [ -z "$bad" ] || die "Linha invalida ou chave duplicada no arquivo de ambiente: $bad"
  for key in APP_DOMAIN APP_RUNTIME_ENV VITE_SUPABASE_URL VITE_SUPABASE_PUBLISHABLE_KEY SUPABASE_URL SUPABASE_PUBLISHABLE_KEY SB_SERVICE_ROLE_KEY; do
    value=$(env_value "$key" "$file" 2>/dev/null || true)
    [ -n "$value" ] || die "Variavel obrigatoria ausente ou vazia: $key"
    case "$value" in *'
'*|*'
'*) die "Valor multilinha recusado: $key" ;; esac
  done
  for key in VITE_SUPABASE_PUBLISHABLE_KEY SUPABASE_PUBLISHABLE_KEY SB_SERVICE_ROLE_KEY; do
    value=$(env_value "$key" "$file")
    compact=$(printf '%s' "$value" | tr -d '[:space:]')
    [ -n "$compact" ] || die "Credencial obrigatoria vazia: $key"
    credential_is_placeholder "$value" && die "Credencial obrigatoria contem placeholder: $key"
  done
  [ "$(env_value APP_RUNTIME_ENV "$file")" = homologacao ] || die 'APP_RUNTIME_ENV deve ser homologacao nesta instalacao.'
  domain=$(env_value APP_DOMAIN "$file")
  case "$domain" in
    http://*|https://*|*/*|*:*|*' '*|.*|*.) die 'APP_DOMAIN deve conter somente o FQDN, sem protocolo, porta ou caminho.' ;;
    *.*) ;;
    *) die 'APP_DOMAIN deve ser um FQDN valido.' ;;
  esac
  for key in VITE_SUPABASE_URL SUPABASE_URL; do
    value=$(env_value "$key" "$file")
    case "$value" in "https://$FREE_HML_SUPABASE_HOST"|"https://$FREE_HML_SUPABASE_HOST/") ;;
      *) die "$key deve apontar exclusivamente para o Supabase Free HML autorizado." ;;
    esac
  done
  public_url=$(env_value VITE_SUPABASE_URL "$file"); runtime_url=$(env_value SUPABASE_URL "$file")
  [ "${public_url%/}" = "${runtime_url%/}" ] || die 'VITE_SUPABASE_URL e SUPABASE_URL devem apontar para o mesmo projeto.'
  for key in CLICKSIGN_PRODUCAO_ACCESS_TOKEN CLICKSIGN_PRODUCAO_WEBHOOK_SECRET; do
    value=$(env_value "$key" "$file" 2>/dev/null || true)
    [ -z "$value" ] || die "$key deve permanecer vazio em homologacao."
  done
  info 'Arquivo de ambiente aprovado (valores sensiveis nao exibidos).'
}

check_templates() {
  for file in compose.yaml Caddyfile Dockerfile; do
    [ -f "$SCRIPT_DIR/templates/$file" ] || die "Template ausente: $file"
  done
}

doctor() {
  check_templates
  if [ "$DRY_RUN" = true ]; then info '[dry-run] verificaria Git, curl, Docker Engine, Compose v2 e acesso ao daemon.'; return; fi
  command -v git >/dev/null 2>&1 || die 'Git nao encontrado.'
  command -v curl >/dev/null 2>&1 || die 'curl nao encontrado; ele e necessario para a readiness HTTPS e Supabase HML.'
  command -v docker >/dev/null 2>&1 || die 'Docker Engine nao encontrado.'
  docker compose version >/dev/null 2>&1 || die 'Plugin Docker Compose v2 nao encontrado.'
  os=$(docker info --format '{{.OSType}}' 2>/dev/null) || die 'Docker inacessivel para o usuario atual.'
  [ "$os" = linux ] || die 'E necessario Docker Engine com containers Linux.'
  info 'Pre-requisitos locais aprovados.'
}

write_state() {
  phase=$1 revision=$2 image=$3 previous=$4 previous_revision=${5:-} requested_ref=${6:-}
  tmp=$PRIVATE_DIR/state.env.tmp.$$
  umask 077
  {
    printf 'SCHEMA=1\n'
    printf 'PHASE=%s\n' "$phase"
    printf 'SOURCE_URL=%s\n' "$SOURCE_URL"
    printf 'REVISION=%s\n' "$revision"
    printf 'IMAGE=%s\n' "$image"
    printf 'PREVIOUS_IMAGE=%s\n' "$previous"
    printf 'PREVIOUS_REVISION=%s\n' "$previous_revision"
    printf 'REQUESTED_REF=%s\n' "$requested_ref"
  } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$STATE_FILE"
}

acquire_lock() {
  [ ! -e "$LOCK_DIR" ] || die "Outra operacao pode estar em andamento: $LOCK_DIR"
  mkdir "$LOCK_DIR" || die 'Nao foi possivel criar o lock operacional.'
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT HUP INT TERM
}

confirm() {
  message=$1
  [ "$ASSUME_YES" = true ] && return
  [ -t 0 ] || die 'Execucao nao interativa exige --yes.'
  printf '%s [digite SIM]: ' "$message"
  read -r answer
  [ "$answer" = SIM ] || die 'Operacao cancelada sem alterar containers.'
}

compose() (
  image=$1
  shift
  APP_SOURCE_DIR=$SOURCE_DIR APP_IMAGE=$image docker compose \
    --project-directory "$DEPLOY_DIR" \
    --env-file "$RUNTIME_ENV" \
    -f "$DEPLOY_DIR/compose.yaml" "$@"
)

wait_health() {
  health_image=$1
  attempts=0
  while [ "$attempts" -lt 24 ]; do
    health=$(compose "$health_image" ps --format json 2>/dev/null | awk '
      /"Service":"app"/ && /"State":"running"/ && /"Health":"healthy"/ { ok=1 }
      END { if(ok) print "healthy" }
    ')
    [ "$health" = healthy ] && return 0
    attempts=$((attempts + 1))
    sleep 5
  done
  return 1
}

wait_https_application() (
  domain=$(env_value APP_DOMAIN "$RUNTIME_ENV")
  attempts=0
  while [ "$attempts" -lt 24 ]; do
    if curl --fail --silent --show-error --output /dev/null \
      --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 20 \
      "https://$domain/" 2>/dev/null; then
      return 0
    fi
    attempts=$((attempts + 1))
    [ "$attempts" -lt 24 ] && sleep 5
  done
  return 1
)

wait_supabase_publishable_key() (
  supabase_url=$1
  publishable_key=$2
  attempts=0
  while [ "$attempts" -lt 3 ]; do
    if printf 'apikey: %s\n' "$publishable_key" | curl --header @- \
      --request GET --fail --silent --show-error --output /dev/null \
      --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 20 \
      "${supabase_url%/}/auth/v1/health" 2>/dev/null; then
      return 0
    fi
    attempts=$((attempts + 1))
    [ "$attempts" -lt 3 ] && sleep 2
  done
  return 1
)

functional_readiness() (
  domain=$(env_value APP_DOMAIN "$RUNTIME_ENV")
  supabase_url=$(env_value SUPABASE_URL "$RUNTIME_ENV")
  runtime_key=$(env_value SUPABASE_PUBLISHABLE_KEY "$RUNTIME_ENV")
  browser_key=$(env_value VITE_SUPABASE_PUBLISHABLE_KEY "$RUNTIME_ENV")

  info "Readiness: validando HTTPS e resposta da aplicacao em $domain."
  if ! wait_https_application; then
    info "Readiness falhou: HTTPS valido ou resposta da aplicacao indisponivel em $domain." >&2
    return 1
  fi

  info 'Readiness: validando conectividade e publishable key do Supabase HML.'
  if ! wait_supabase_publishable_key "$supabase_url" "$runtime_key"; then
    info 'Readiness falhou: SUPABASE_URL ou SUPABASE_PUBLISHABLE_KEY nao foi aceita pelo Auth HML.' >&2
    return 1
  fi
  if [ "$browser_key" != "$runtime_key" ] && ! wait_supabase_publishable_key "$supabase_url" "$browser_key"; then
    info 'Readiness falhou: VITE_SUPABASE_PUBLISHABLE_KEY nao foi aceita pelo Auth HML.' >&2
    return 1
  fi

  info 'Readiness funcional aprovada: HTTPS, aplicacao e Supabase HML responderam.'
)

prepare_deploy_files() {
  mkdir -p "$DEPLOY_DIR" "$PRIVATE_DIR"
  chmod 700 "$PRIVATE_DIR"
  for file in compose.yaml Caddyfile Dockerfile; do cp "$SCRIPT_DIR/templates/$file" "$DEPLOY_DIR/$file"; done
  chmod 600 "$RUNTIME_ENV"
}

resolve_revision() {
  git -C "$SOURCE_DIR" rev-parse --verify 'HEAD^{commit}'
}

validate_source_tree() {
  for file in package.json bun.lock components.json tsconfig.json vite.config.ts src public; do
    [ -e "$SOURCE_DIR/$file" ] || die "Arquivo obrigatorio ausente no ref escolhido: $file"
  done
}

require_source_checkout() {
  [ -d "$SOURCE_DIR/.git" ] && [ ! -L "$SOURCE_DIR" ] && [ ! -L "$SOURCE_DIR/.git" ] ||
    die 'Checkout Git gerenciado da aplicacao nao encontrado ou ambiguo.'
}

prepare_initial_checkout() (
  requested_ref=$1
  case "$requested_ref" in -*|*..*|*[!A-Za-z0-9._/-]*|*'
'*) die 'REQUESTED_REF invalido no estado da instalacao.' ;; esac

  if [ ! -e "$SOURCE_DIR" ]; then
    git clone --no-checkout "$SOURCE_URL" "$SOURCE_DIR" >/dev/null ||
      die 'Clone interrompido. O estado foi preservado; use resume para tentar novamente.'
  else
    [ -d "$SOURCE_DIR" ] && [ ! -L "$SOURCE_DIR" ] &&
      [ -d "$SOURCE_DIR/.git" ] && [ ! -L "$SOURCE_DIR/.git" ] ||
      die 'Diretorio source existente nao e um checkout Git gerenciado inequivoco; nada foi alterado.'
    origin=$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null || true)
    [ "$origin" = "$SOURCE_URL" ] ||
      die 'Origem do checkout existente diverge do estado; retomada recusada sem alterar arquivos.'
  fi

  git -C "$SOURCE_DIR" fetch --depth 1 origin "$requested_ref" >/dev/null ||
    die 'Fetch interrompido. O checkout existente foi preservado; use resume para tentar novamente.'
  target_revision=$(git -C "$SOURCE_DIR" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null) ||
    die 'Fetch concluido sem revisao verificavel; retomada recusada.'

  worktree_has_files=false
  for entry in "$SOURCE_DIR"/* "$SOURCE_DIR"/.[!.]* "$SOURCE_DIR"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ "$entry" = "$SOURCE_DIR/.git" ] && continue
    worktree_has_files=true
    break
  done
  if [ "$worktree_has_files" = true ]; then
    [ -z "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=all 2>/dev/null)" ] ||
      die 'Checkout parcial ou com arquivos locais detectado; retomada recusada sem sobrescrever nada.'
    current_revision=$(git -C "$SOURCE_DIR" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
    [ "$current_revision" = "$target_revision" ] ||
      die 'Checkout existente aponta para outra revisao; retomada recusada sem sobrescrever arquivos.'
  else
    git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD >/dev/null ||
      die 'Checkout interrompido. Arquivos existentes foram preservados; revise o source antes de retomar.'
  fi

  [ -z "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=all 2>/dev/null)" ] ||
    die 'Checkout resultante nao esta limpo; retomada recusada.'
  printf '%s\n' "$target_revision"
)

build_and_start() {
  revision=$1 previous=$2 previous_revision=${3:-}
  requested_ref=$REF
  if [ -z "$requested_ref" ] && [ -f "$STATE_FILE" ]; then
    requested_ref=$(state_value REQUESTED_REF 2>/dev/null || true)
  fi
  short=$(printf '%s' "$revision" | cut -c1-12)
  image=amanda-partner-hub:$short
  validate_source_tree
  if [ -z "$previous" ]; then
    write_state prepared "$revision" "$image" "$previous" "$previous_revision" "$requested_ref"
  fi
  if ! compose "$image" config --quiet; then
    if [ -n "$previous" ] && [ -n "$previous_revision" ]; then
      git -C "$SOURCE_DIR" checkout --detach "$previous_revision" >/dev/null 2>&1 ||
        die 'Falha no Compose e nao foi possivel restaurar o checkout anterior.'
    fi
    die 'Falha na validacao do Docker Compose. Nenhuma nova versao foi iniciada.'
  fi
  if ! compose "$image" build --pull app; then
    if [ -n "$previous" ] && [ -n "$previous_revision" ]; then
      git -C "$SOURCE_DIR" checkout --detach "$previous_revision" >/dev/null 2>&1 ||
        die 'Falha no build e nao foi possivel restaurar o checkout anterior.'
    fi
    die 'Falha na construcao da imagem. Nenhuma nova versao foi iniciada.'
  fi
  if [ -n "$previous" ]; then
    write_state prepared "$revision" "$image" "$previous" "$previous_revision" "$requested_ref"
  fi
  confirm "Iniciar o Amanda Partner Hub com a imagem $image?"
  if ! compose "$image" up -d --no-build; then
    info 'Falha ao iniciar a nova imagem. Tentando recuperacao, se disponivel.' >&2
  elif wait_health "$image" && functional_readiness; then
    write_state ready "$revision" "$image" "$previous" "$previous_revision" "$requested_ref"
    info "Instalacao saudavel. Imagem ativa: $image"
    return
  fi
  info 'A nova aplicacao nao passou pelo healthcheck/readiness. Consulte o diagnostico e os logs; nenhum volume ou backup foi removido.' >&2
  if [ -n "$previous" ]; then
    info "Tentando recuperar a imagem anterior: $previous" >&2
    compose "$previous" up -d --no-build app
    wait_health "$previous" || die 'A recuperacao automatica tambem nao ficou saudavel.'
    functional_readiness || die 'A imagem anterior voltou, mas a readiness funcional tambem falhou.'
    if [ -n "$previous_revision" ]; then
      git -C "$SOURCE_DIR" checkout --detach "$previous_revision" >/dev/null 2>&1 || true
    else
      previous_revision=$revision
    fi
    write_state ready "$previous_revision" "$previous" "$image" "$revision" "$requested_ref"
    die 'Atualizacao revertida para a imagem anterior.'
  fi
  die 'Instalacao preparada, mas nao saudavel. Corrija a causa e execute resume.'
}

install_action() {
  [ -n "$ENV_INPUT" ] || die 'install exige --env.'
  [ -n "$REF" ] || die 'install exige --ref (branch, tag ou commit aprovado).'
  validate_env "$ENV_INPUT"
  check_templates
  if [ "$DRY_RUN" = true ]; then
    info "[dry-run] criaria $TARGET, clonaria $SOURCE_URL em $SOURCE_DIR no ref $REF, validaria Compose, construiria uma imagem imutavel e iniciaria app + Caddy."
    return
  fi
  [ ! -e "$TARGET" ] || die 'Diretorio de instalacao ja existe. Use update ou resume; nada foi sobrescrito.'
  doctor
  mkdir -p "$TARGET" "$PRIVATE_DIR"
  chmod 700 "$PRIVATE_DIR"
  acquire_lock
  cp "$ENV_INPUT" "$RUNTIME_ENV"
  prepare_deploy_files
  write_state preparing '' '' '' '' "$REF"
  revision=$(prepare_initial_checkout "$REF")
  build_and_start "$revision" ''
}

require_installation() {
  [ -f "$STATE_FILE" ] || die 'Instalacao gerenciada nao encontrada.'
  [ ! -L "$STATE_FILE" ] || die 'Arquivo de estado nao pode ser link simbolico.'
  [ -f "$RUNTIME_ENV" ] || die 'Arquivo privado de ambiente nao encontrado.'
  [ "$(state_value SCHEMA 2>/dev/null || true)" = 1 ] || die 'Schema do estado ausente ou nao suportado.'
  SOURCE_URL=$(state_value SOURCE_URL)
  case "$SOURCE_URL" in
    https://*/*) ;;
    *) die 'Origem registrada no estado nao usa HTTPS valido.' ;;
  esac
  case "$SOURCE_URL" in *'@'*|*'?'*|*'#'*|*'
'*) die 'Origem registrada no estado contem credencial ou caracteres recusados.' ;; esac
  validate_env "$RUNTIME_ENV"
}

resume_action() {
  require_installation
  phase=$(state_value PHASE)
  case "$phase" in
    preparing)
      [ -z "$(state_value REVISION)$(state_value IMAGE)$(state_value PREVIOUS_IMAGE)" ] ||
        die 'Estado preparing contem revisao ou imagem inesperada; retomada recusada.'
      requested_ref=$(state_value REQUESTED_REF 2>/dev/null || true)
      [ -n "$requested_ref" ] || die 'Estado preparing sem REQUESTED_REF; retomada ambigua recusada.'
      revision=$(prepare_initial_checkout "$requested_ref")
      build_and_start "$revision" ''
      ;;
    prepared)
      require_source_checkout
      revision=$(resolve_revision)
      [ "$revision" = "$(state_value REVISION)" ] || die 'O checkout mudou desde a falha; revise antes de retomar.'
      build_and_start "$revision" "$(state_value PREVIOUS_IMAGE)" "$(state_value PREVIOUS_REVISION 2>/dev/null || true)"
      ;;
    *) die 'resume so e permitido para uma instalacao preparing ou prepared e incompleta.' ;;
  esac
}

update_action() {
  [ -n "$REF" ] || die 'update exige --ref explicito (tag, branch ou commit aprovado).'
  require_installation
  require_source_checkout
  [ "$(state_value PHASE)" = ready ] || die 'Instalacao incompleta. Use resume.'
  [ -z "$(git -C "$SOURCE_DIR" status --porcelain)" ] || die 'Checkout possui alteracoes locais; atualizacao recusada.'
  previous=$(state_value IMAGE)
  if [ "$DRY_RUN" = true ]; then
    info "[dry-run] buscaria $REF, construiria nova imagem antes da troca, verificaria health e preservaria $previous para rollback."
    return
  fi
  doctor
  acquire_lock
  old_revision=$(resolve_revision)
  git -C "$SOURCE_DIR" fetch --depth 1 origin "$REF"
  git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD
  revision=$(resolve_revision)
  build_and_start "$revision" "$previous" "$old_revision"
}

managed_action() {
  require_installation
  image=$(state_value IMAGE)
  case "$ACTION" in
    status) compose "$image" ps ;;
    logs) compose "$image" logs --tail 200 app caddy ;;
    start) confirm 'Iniciar os containers preservados?'; compose "$image" up -d --no-build ;;
    stop) confirm 'Parar os containers sem remover volumes?'; compose "$image" stop ;;
    rollback)
      require_source_checkout
      previous=$(state_value PREVIOUS_IMAGE)
      previous_revision=$(state_value PREVIOUS_REVISION 2>/dev/null || true)
      [ -n "$previous" ] || die 'Nenhuma imagem anterior registrada.'
      [ -n "$previous_revision" ] || die 'Nenhuma revisao anterior registrada.'
      confirm "Voltar a aplicacao para $previous? Isso nao altera o Supabase."
      compose "$previous" up -d --no-build app
      wait_health "$previous" || die 'A imagem anterior nao ficou saudavel.'
      functional_readiness || die 'A imagem anterior iniciou, mas nao passou pela readiness funcional.'
      current_revision=$(state_value REVISION)
      git -C "$SOURCE_DIR" checkout --detach "$previous_revision"
      write_state ready "$previous_revision" "$previous" "$image" "$current_revision" "$(state_value REQUESTED_REF 2>/dev/null || true)"
      info "Rollback concluido para $previous."
      ;;
  esac
}

case "$ACTION" in
  help) usage ;;
  doctor) doctor ;;
  validate) [ -n "$ENV_INPUT" ] || die 'validate exige --env.'; check_templates; validate_env "$ENV_INPUT" ;;
  install) install_action ;;
  resume) [ "$DRY_RUN" = false ] || die 'Use install --dry-run ou update --dry-run; resume depende de estado real.'; doctor; acquire_lock; resume_action ;;
  update) update_action ;;
  status|logs|start|stop|rollback)
    [ "$DRY_RUN" = false ] || die "$ACTION nao e executado em dry-run."
    doctor
    case "$ACTION" in start|stop|rollback) acquire_lock ;; esac
    managed_action
    ;;
esac
