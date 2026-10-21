#!/usr/bin/env bash
# Traz a skill `superdb` publicada no site para skills/superdb deste repositório.
#
# A fonte da skill mora num repositório privado. O site a publica em
# https://superdb.com.br/skills/superdb/, com um manifest.json que lista cada
# arquivo com sha256 e tamanho, mais uma `versao` (o sha256 do conjunto). Este
# script roda de hora em hora no workflow .github/workflows/sincronizar-skill.yml.
#
# O que ele garante:
#   - site fora do ar, ou manifest ainda não publicado (404): sai com 0, sem tocar em nada;
#   - mesma `versao` já registrada em skills/superdb/.manifest.json: sai com 0;
#   - manifest vazio, malformado ou com caminho fora da pasta (`..`, `/` no começo): FALHA;
#   - arquivo baixado com sha256 ou tamanho diferente do manifest: FALHA;
#   - conteúdo com cara de segredo: FALHA, listando só o nome do arquivo;
#   - o que saiu do manifest some da pasta; a versão PATCH do plugin sobe.
#
# Só usa curl, jq, sha256sum (ou shasum) e git.
#
# Variáveis:
#   SKILL_URL            base da skill (padrão: https://superdb.com.br/skills/superdb)
#   VARREDURA_INTERNA    regex extra (ERE) com nomes internos; vem de um secret do
#                        repositório, porque escrever esses nomes aqui seria vazá-los
#   VARREDURA_INTERNA_ARQUIVO  o mesmo, lido de um arquivo (para rodar fora do Actions)
#   SINCRONIZAR_COMMIT=1 commita (sem isso, só atualiza a pasta e diz o que mudou)
#   SINCRONIZAR_PUSH=1   dá push depois do commit
set -euo pipefail

BASE="${SKILL_URL:-https://superdb.com.br/skills/superdb}"
BASE="${BASE%/}"
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DESTINO="$RAIZ/skills/superdb"
REGISTRO="$DESTINO/.manifest.json"
PLUGIN_JSON="$RAIZ/.claude-plugin/plugin.json"

aviso() { echo "::notice::$*"; }
erro() { echo "::error::$*" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then
  sha() { sha256sum "$@"; }
else
  sha() { shasum -a 256 "$@"; }
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. O manifest ─────────────────────────────────────────────────────────────
codigo=$(curl -sS -L --proto '=https,http' --max-time 30 --retry 2 \
  -o "$TMP/manifest.json" -w '%{http_code}' "$BASE/manifest.json" 2>"$TMP/curl.err") || {
  aviso "site fora do ar ou sem rede ($(head -c 200 "$TMP/curl.err")); nada feito"
  exit 0
}
case "$codigo" in
  200) ;;
  404) aviso "o site ainda não publica $BASE/manifest.json (404); nada feito"; exit 0 ;;
  *)   aviso "o site respondeu HTTP $codigo para o manifest; nada feito"; exit 0 ;;
esac

jq -e . "$TMP/manifest.json" >/dev/null 2>&1 || erro "manifest não é JSON válido"

versao=$(jq -r '.versao // empty' "$TMP/manifest.json")
[[ "$versao" =~ ^[0-9a-f]{64}$ ]] || erro "manifest sem versao válida"

total=$(jq -r 'if (.arquivos|type) == "array" then (.arquivos|length) else -1 end' "$TMP/manifest.json")
[ "$total" -gt 0 ] || erro "manifest com a lista de arquivos vazia ou ausente"

# Cada entrada: caminho relativo e limpo, sha256 hex, tamanho inteiro.
jq -r '.arquivos[] | [(.caminho|tostring), (.sha256|tostring), (.tamanho|tostring)] | @tsv' \
  "$TMP/manifest.json" > "$TMP/lista.tsv"

: > "$TMP/linhas"
while IFS=$'\t' read -r caminho hash tamanho; do
  [[ "$caminho" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || erro "caminho recusado no manifest: $caminho"
  case "/$caminho/" in
    */../* | */./*) erro "caminho com '..' ou '.' no manifest: $caminho" ;;
  esac
  case "$caminho" in
    manifest.json | .manifest.json) erro "caminho reservado no manifest: $caminho" ;;
  esac
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || erro "sha256 inválido para $caminho"
  [[ "$tamanho" =~ ^[0-9]+$ ]] || erro "tamanho inválido para $caminho"
  printf '%s  %s\n' "$hash" "$caminho" >> "$TMP/linhas"
done < "$TMP/lista.tsv"

[ "$(cut -d' ' -f3- "$TMP/linhas" | sort | uniq -d | wc -l | tr -d ' ')" = 0 ] \
  || erro "caminho repetido no manifest"

# A versao é o sha256 das linhas "<sha256>  <caminho>" em ordem de caminho.
LC_ALL=C sort -k2 "$TMP/linhas" > "$TMP/linhas.ord"
conta=$(sha "$TMP/linhas.ord" | cut -d' ' -f1)
[ "$conta" = "$versao" ] || erro "a versao do manifest não bate com a lista de arquivos"

# ── 2. Já está em dia? ────────────────────────────────────────────────────────
if [ -f "$REGISTRO" ] && [ "$(jq -r '.versao // empty' "$REGISTRO" 2>/dev/null)" = "$versao" ]; then
  aviso "skill já está na versão $versao; nada feito"
  exit 0
fi

# ── 3. Baixar e conferir cada arquivo ─────────────────────────────────────────
NOVA="$TMP/nova"
mkdir -p "$NOVA"
while IFS=$'\t' read -r caminho hash tamanho; do
  mkdir -p "$NOVA/$(dirname "$caminho")"
  if ! curl -sS -f -L --proto '=https,http' --max-time 30 --retry 2 \
      -o "$NOVA/$caminho" "$BASE/$caminho" 2>"$TMP/curl.err"; then
    aviso "não consegui baixar $caminho ($(head -c 200 "$TMP/curl.err")); nada feito"
    exit 0
  fi
  obtido=$(sha "$NOVA/$caminho" | cut -d' ' -f1)
  [ "$obtido" = "$hash" ] || erro "sha256 de $caminho não bate com o manifest"
  [ "$(wc -c < "$NOVA/$caminho" | tr -d ' ')" = "$tamanho" ] || erro "tamanho de $caminho não bate com o manifest"
done < "$TMP/lista.tsv"

# ── 4. Varredura de segredos ──────────────────────────────────────────────────
# Mostra só o NOME do arquivo: o repositório e o log do Actions são públicos.
PADROES=(
  'sdb_pmk_[A-Za-z0-9]{10}'
  'sdb_gk_[A-Za-z0-9]{10}'
  'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+'
  'postgres(ql)?://[^:/@[:space:]]+:[^@[:space:]]+@'
  'BEGIN [A-Z ]*PRIVATE KEY'
  'coolify\.'
)
printf '%s\n' "${PADROES[@]}" > "$TMP/padroes"
if [ -n "${VARREDURA_INTERNA:-}" ]; then
  printf '%s\n' "$VARREDURA_INTERNA" >> "$TMP/padroes"
elif [ -n "${VARREDURA_INTERNA_ARQUIVO:-}" ] && [ -s "$VARREDURA_INTERNA_ARQUIVO" ]; then
  cat "$VARREDURA_INTERNA_ARQUIVO" >> "$TMP/padroes"
elif [ "${SINCRONIZAR_COMMIT:-}" = 1 ]; then
  erro "VARREDURA_INTERNA ausente: sem ela a varredura não cobre os nomes internos; nada commitado"
fi
# Linha vazia no arquivo de padrões casa com TUDO: fora com elas (o secret pode
# chegar com uma quebra de linha no fim).
grep -v '^[[:space:]]*$' "$TMP/padroes" > "$TMP/padroes.limpos" || true
mv "$TMP/padroes.limpos" "$TMP/padroes"
# Controle: a lista pega um exemplo do que ela diz pegar. Um padrão quebrado
# passaria tudo como "limpo" para sempre.
printf 'chave %s%s\n' 'sdb_pmk_' 'a1B2c3D4e5F6g7' > "$TMP/controle"
grep -qE -f "$TMP/padroes" "$TMP/controle" || erro "a varredura de segredos não pega nem o exemplo de controle"
# E o contrário: um padrão que casa com qualquer texto barraria toda sincronização.
printf 'Conecte o app com createClient(url, anonKey).\n' > "$TMP/neutro"
if grep -qE -f "$TMP/padroes" "$TMP/neutro"; then erro "a varredura de segredos casa com texto comum"; fi
# grep: 0 achou, 1 não achou, 2 erro (regex inválido, arquivo ilegível). Erro
# NÃO pode virar "limpo".
status=0
grep -rlE -f "$TMP/padroes" "$NOVA" > "$TMP/achados" || status=$?
case "$status" in
  0) erro "varredura de segredos achou algo em: $(sed "s|^$NOVA/||" "$TMP/achados" | tr '\n' ' ')" ;;
  1) ;;
  *) erro "a varredura de segredos não rodou (grep saiu com $status)" ;;
esac

# ── 5. Trocar a pasta ─────────────────────────────────────────────────────────
cp "$TMP/manifest.json" "$NOVA/.manifest.json"
rm -rf "$DESTINO"
mkdir -p "$(dirname "$DESTINO")"
mv "$NOVA" "$DESTINO"

cd "$RAIZ"
git add -A skills/superdb
mudados=$(git diff --cached --name-status -- skills/superdb | grep -v $'\tskills/superdb/.manifest.json$' || true)

if [ -z "$mudados" ]; then
  aviso "conteúdo igual ao do site; só registro a versão $versao"
  titulo="skill: registra a versão do site (${versao:0:12}), sem mudança de conteúdo"
else
  atual=$(jq -r '.version' "$PLUGIN_JSON")
  [[ "$atual" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || erro "version do plugin.json fora do padrão X.Y.Z: $atual"
  nova_versao="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
  jq --arg v "$nova_versao" '.version = $v' "$PLUGIN_JSON" > "$TMP/plugin.json"
  mv "$TMP/plugin.json" "$PLUGIN_JSON"
  git add "$PLUGIN_JSON"
  titulo="skill: sincronizada com o site (plugin $nova_versao)"
fi

echo "$titulo"
[ -z "$mudados" ] || echo "$mudados"

if [ "${SINCRONIZAR_COMMIT:-}" = 1 ]; then
  {
    echo "$titulo"
    echo
    echo "Versão do site: $versao"
    if [ -n "$mudados" ]; then
      echo
      echo "Arquivos (A novo, M mudou, D saiu do site):"
      while IFS= read -r linha; do echo "  $linha"; done <<< "$mudados"
    fi
  } > "$TMP/mensagem"
  git -c user.name="SuperDB (sincronização automática)" \
      -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
      commit -q -F "$TMP/mensagem"
  if [ "${SINCRONIZAR_PUSH:-}" = 1 ]; then
    git push -q origin HEAD
  fi
fi
