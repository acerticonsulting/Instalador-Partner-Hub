#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

pass=0
fail() { echo "FALHA: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }

sh -n "$root/partner-hub.sh"
ok 'sintaxe POSIX shell'

for file in compose.yaml Caddyfile Dockerfile runtime.env.example; do
  [[ -s "$root/templates/$file" ]] || fail "template ausente: $file"
done
ok 'templates presentes e nao vazios'

cp "$root/templates/runtime.env.example" "$tmp/valid.env"
chmod 600 "$tmp/valid.env"
sed 's#replace-with-free-project-publishable-key#sb_publishable_valid_test_key#g; s#replace-on-vps-with-free-project-service-role-key#sb_secret_valid_test_key#' \
  "$tmp/valid.env" > "$tmp/valid.env.rendered"
mv "$tmp/valid.env.rendered" "$tmp/valid.env"
sh "$root/partner-hub.sh" validate --env "$tmp/valid.env" >/dev/null
ok 'ambiente preenchido aceito sem exibir valores'

grep -v '^SB_SERVICE_ROLE_KEY=' "$tmp/valid.env" > "$tmp/missing.env"
if sh "$root/partner-hub.sh" validate --env "$tmp/missing.env" >/dev/null 2>&1; then
  fail 'variavel obrigatoria ausente foi aceita'
fi
ok 'variavel obrigatoria ausente e recusada'

for credential_key in VITE_SUPABASE_PUBLISHABLE_KEY SUPABASE_PUBLISHABLE_KEY SB_SERVICE_ROLE_KEY; do
  for invalid_credential in '' '   ' 'replace-with-project-key' 'CHANGE_ME' '<credential>'; do
    sed "s#^${credential_key}=.*#${credential_key}=$invalid_credential#" \
      "$tmp/valid.env" > "$tmp/invalid-credential.env"
    if sh "$root/partner-hub.sh" validate --env "$tmp/invalid-credential.env" >/dev/null 2>&1; then
      fail "credencial obrigatoria vazia ou placeholder foi aceita: $credential_key"
    fi
  done
done
ok 'credenciais obrigatorias vazias e placeholders sao recusados'

for production_key in CLICKSIGN_PRODUCAO_ACCESS_TOKEN CLICKSIGN_PRODUCAO_WEBHOOK_SECRET; do
  sed "s#^${production_key}=.*#${production_key}=production-secret-must-not-enter-hml#" \
    "$tmp/valid.env" > "$tmp/clicksign-production.env"
  if sh "$root/partner-hub.sh" validate --env "$tmp/clicksign-production.env" >/dev/null 2>&1; then
    fail "credencial Clicksign de producao foi aceita em HML: $production_key"
  fi
done
ok 'credenciais Clicksign de producao preenchidas sao recusadas em HML'

cp "$tmp/valid.env" "$tmp/duplicate.env"
printf '\nAPP_DOMAIN=duplicate.example.com\n' >> "$tmp/duplicate.env"
if sh "$root/partner-hub.sh" validate --env "$tmp/duplicate.env" >/dev/null 2>&1; then
  fail 'chave duplicada foi aceita'
fi
ok 'chave de ambiente duplicada e recusada'

sed 's#APP_DOMAIN=partners.example.com#APP_DOMAIN=https://partners.example.com/path#' "$tmp/valid.env" > "$tmp/domain.env"
if sh "$root/partner-hub.sh" validate --env "$tmp/domain.env" >/dev/null 2>&1; then
  fail 'dominio com protocolo/caminho foi aceito'
fi
ok 'dominio invalido e recusado'

dry_target="$tmp/must-not-exist"
sh "$root/partner-hub.sh" install --dir "$dry_target" --env "$tmp/valid.env" --ref test-commit --dry-run >/dev/null
[[ ! -e "$dry_target" ]] || fail 'dry-run escreveu no destino'
sh "$root/partner-hub.sh" install --dir "$dry_target" --env "$tmp/valid.env" --ref test-commit --dry-run >/dev/null
[[ ! -e "$dry_target" ]] || fail 'dry-run repetido escreveu no destino'
ok 'dry-run repetivel, sem escrita e sem Docker/Git'

mkdir "$tmp/existing"
if sh "$root/partner-hub.sh" install --dir "$tmp/existing" --env "$tmp/valid.env" --ref test-commit --yes >/dev/null 2>&1; then
  fail 'instalacao aceitou sobrescrever diretorio existente'
fi
ok 'diretorio existente e preservado antes de acessar Docker/Git'

if grep -E 'docker[[:space:]]+(system|volume|image)[[:space:]]+prune|docker[[:space:]]+compose[^\n]*(down|rm)|down[[:space:]]+-v|supabase[[:space:]]+(db|migration)|db[[:space:]]+reset' "$root/partner-hub.sh"; then
  fail 'comando destrutivo ou migration encontrado no instalador'
fi
ok 'scripts sem prune/down/rm/db reset/migrations'

if grep -R -E 'eyJ[A-Za-z0-9_-]{20,}|service_role[[:space:]]*=' "$root/templates"; then
  fail 'possivel credencial real encontrada nos templates'
fi
ok 'templates sem padroes de credenciais reais'

grep -q 'condition: service_healthy' "$root/templates/compose.yaml" || fail 'dependencia de health ausente'
grep -q 'healthcheck:' "$root/templates/compose.yaml" || fail 'healthcheck ausente'
ok 'health checks declarados'

caddyfile="$root/templates/Caddyfile"
grep -q 'image: caddy:2\.10\.2-alpine' "$root/templates/compose.yaml" ||
  fail 'versao esperada do Caddy foi alterada'
grep -q '^[[:space:]]*format filter {$' "$caddyfile" || fail 'filtro de logs do Caddy ausente'
grep -q '^[[:space:]]*wrap console$' "$caddyfile" || fail 'formato operacional console nao foi preservado'
grep -q '^[[:space:]]*request>uri query {$' "$caddyfile" || fail 'filtro de query da URI ausente'
for key in access_token refresh_token id_token token token_hash code state ms_code ms_state otp password client_secret api_key apikey authorization signature sig hmac; do
  grep -q "^[[:space:]]*replace $key REDACTED$" "$caddyfile" ||
    fail "parametro sensivel sem redacao no Caddy: $key"
done
grep -q '^[[:space:]]*reverse_proxy app:3000$' "$caddyfile" || fail 'proxy da aplicacao foi alterado'
ok 'logs do Caddy redigem parametros sensiveis sem alterar o proxy'

readiness_target="$tmp/readiness-target"
mkdir -p "$readiness_target/private" "$tmp/mock-bin"
cp "$tmp/valid.env" "$readiness_target/private/runtime.env"
sed '/^case "$ACTION" in$/,$d' "$root/partner-hub.sh" > "$tmp/readiness-harness.sh"
printf '\nfunctional_readiness\n' >> "$tmp/readiness-harness.sh"
cat > "$tmp/mock-bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/auth/v1/health'*)
    cat >/dev/null
    [ "${MOCK_SUPABASE_FAILURE:-false}" != true ]
    ;;
  *) [ "${MOCK_HTTPS_FAILURE:-false}" != true ] ;;
esac
EOF
cat > "$tmp/mock-bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/mock-bin/curl" "$tmp/mock-bin/sleep"

readiness_output=$(PATH="$tmp/mock-bin:$PATH" PARTNER_HUB_INSTALL_DIR="$readiness_target" \
  sh "$tmp/readiness-harness.sh" 2>&1) || fail 'readiness simulada valida foi recusada'
if printf '%s' "$readiness_output" | grep -q 'sb_publishable_valid_test_key'; then
  fail 'readiness exibiu publishable key no diagnostico'
fi
if PATH="$tmp/mock-bin:$PATH" PARTNER_HUB_INSTALL_DIR="$readiness_target" MOCK_HTTPS_FAILURE=true \
  sh "$tmp/readiness-harness.sh" >/dev/null 2>&1; then
  fail 'readiness aceitou falha HTTPS/aplicacao'
fi
if PATH="$tmp/mock-bin:$PATH" PARTNER_HUB_INSTALL_DIR="$readiness_target" MOCK_SUPABASE_FAILURE=true \
  sh "$tmp/readiness-harness.sh" >/dev/null 2>&1; then
  fail 'readiness aceitou falha de conectividade/chave Supabase HML'
fi
grep -q -- "--header @-" "$root/partner-hub.sh" || fail 'publishable key pode aparecer na linha de processo'
if sed -n '/^functional_readiness()/,/^)/p' "$root/partner-hub.sh" | grep -q 'SB_SERVICE_ROLE_KEY'; then
  fail 'readiness usa credencial privilegiada do Supabase'
fi
grep -q 'elif wait_health "$image" && functional_readiness; then' "$root/partner-hub.sh" ||
  fail 'estado ready nao esta condicionado a healthcheck e readiness'
ok 'readiness valida HTTPS, aplicacao e Supabase HML sem expor ou usar segredo privilegiado'

install_mock_bin="$tmp/install-mock-bin"
mkdir -p "$install_mock_bin"
cat > "$install_mock_bin/git" <<'EOF'
#!/bin/sh
if [ "$1" = clone ]; then
  [ "${MOCK_GIT_FAILURE:-}" != clone ] || exit 71
  origin=$3
  destination=$4
  mkdir -p "$destination/.git"
  printf '%s\n' "$origin" > "$destination/.git/origin"
  exit 0
fi
[ "$1" = -C ] || exit 72
repo=$2
shift 2
case "$1" in
  remote)
    [ "$2" = get-url ] && [ "$3" = origin ] || exit 73
    cat "$repo/.git/origin"
    ;;
  fetch)
    [ "${MOCK_GIT_FAILURE:-}" != fetch ] || exit 74
    printf '%s\n' '0123456789abcdef0123456789abcdef01234567' > "$repo/.git/FETCH_HEAD"
    ;;
  rev-parse)
    case "$*" in
      *FETCH_HEAD*) cat "$repo/.git/FETCH_HEAD" ;;
      *HEAD*) cat "$repo/.git/HEAD" ;;
      *) exit 75 ;;
    esac
    ;;
  checkout)
    [ "${MOCK_GIT_FAILURE:-}" != checkout ] || exit 76
    cp "$repo/.git/FETCH_HEAD" "$repo/.git/HEAD"
    : > "$repo/package.json"
    : > "$repo/bun.lock"
    : > "$repo/components.json"
    : > "$repo/tsconfig.json"
    : > "$repo/vite.config.ts"
    mkdir -p "$repo/src" "$repo/public"
    ;;
  status) ;;
  *) exit 77 ;;
esac
EOF
cat > "$install_mock_bin/docker" <<'EOF'
#!/bin/sh
if [ "$1" = info ]; then
  printf '%s\n' linux
  exit 0
fi
[ "$1" = compose ] || exit 81
for arg in "$@"; do
  if [ "$arg" = ps ]; then
    printf '%s\n' '{"Service":"app","State":"running","Health":"healthy"}'
    exit 0
  fi
done
exit 0
EOF
cat > "$install_mock_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in *'--header @-'*) cat >/dev/null ;; esac
exit 0
EOF
cat > "$install_mock_bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$install_mock_bin/git" "$install_mock_bin/docker" "$install_mock_bin/curl" "$install_mock_bin/sleep"

for interrupted_stage in clone fetch checkout; do
  interrupted_target="$tmp/interrupted-$interrupted_stage"
  if PATH="$install_mock_bin:$PATH" MOCK_GIT_FAILURE="$interrupted_stage" \
    sh "$root/partner-hub.sh" install --dir "$interrupted_target" --env "$tmp/valid.env" \
      --source https://example.test/partners-amanda.git --ref approved-ref --yes >/dev/null 2>&1; then
    fail "instalacao nao interrompeu na etapa simulada: $interrupted_stage"
  fi
  grep -q '^PHASE=preparing$' "$interrupted_target/private/state.env" ||
    fail "estado preparing ausente apos falha de $interrupted_stage"
  grep -q '^REQUESTED_REF=approved-ref$' "$interrupted_target/private/state.env" ||
    fail "ref de retomada ausente apos falha de $interrupted_stage"
  runtime_before=$(cksum "$interrupted_target/private/runtime.env")
  printf '\n# preserve-on-resume\n' >> "$interrupted_target/deploy/Caddyfile"

  PATH="$install_mock_bin:$PATH" sh "$root/partner-hub.sh" resume \
    --dir "$interrupted_target" --yes >/dev/null 2>&1 ||
    fail "resume falhou apos interrupcao de $interrupted_stage"
  grep -q '^PHASE=ready$' "$interrupted_target/private/state.env" ||
    fail "resume nao concluiu apos interrupcao de $interrupted_stage"
  [ "$runtime_before" = "$(cksum "$interrupted_target/private/runtime.env")" ] ||
    fail "resume sobrescreveu credenciais apos falha de $interrupted_stage"
  grep -q '^# preserve-on-resume$' "$interrupted_target/deploy/Caddyfile" ||
    fail "resume sobrescreveu configuracao apos falha de $interrupted_stage"
done
ok 'resume recupera interrupcoes de clone, fetch e checkout sem sobrescrever configuracao'

ambiguous_target="$tmp/interrupted-ambiguous"
PATH="$install_mock_bin:$PATH" MOCK_GIT_FAILURE=clone \
  sh "$root/partner-hub.sh" install --dir "$ambiguous_target" --env "$tmp/valid.env" \
    --source https://example.test/partners-amanda.git --ref approved-ref --yes >/dev/null 2>&1 || true
mkdir -p "$ambiguous_target/source"
printf '%s\n' 'preserve-me' > "$ambiguous_target/source/unmanaged.txt"
if PATH="$install_mock_bin:$PATH" sh "$root/partner-hub.sh" resume \
  --dir "$ambiguous_target" --yes >/dev/null 2>&1; then
  fail 'resume aceitou diretorio source ambiguo'
fi
[ "$(cat "$ambiguous_target/source/unmanaged.txt")" = preserve-me ] ||
  fail 'arquivo ambiguo foi alterado ou removido'
grep -q '^PHASE=preparing$' "$ambiguous_target/private/state.env" ||
  fail 'estado ambiguo nao permaneceu preparing'
ok 'resume recusa estado ambiguo sem apagar arquivos'

echo "Todos os $pass testes locais passaram. Nenhum container foi iniciado."
