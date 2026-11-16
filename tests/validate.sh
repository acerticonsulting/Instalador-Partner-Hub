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
sh "$root/partner-hub.sh" validate --env "$tmp/valid.env" >/dev/null
ok 'template de ambiente aceito sem exibir valores'

grep -v '^SB_SERVICE_ROLE_KEY=' "$tmp/valid.env" > "$tmp/missing.env"
if sh "$root/partner-hub.sh" validate --env "$tmp/missing.env" >/dev/null 2>&1; then
  fail 'variavel obrigatoria ausente foi aceita'
fi
ok 'variavel obrigatoria ausente e recusada'

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

echo "Todos os $pass testes locais passaram. Nenhum container foi iniciado."
