#!/bin/sh
# Mantém um clone local deste plugin em dia com o GitHub (git pull --ff-only).
#
# Feito para rodar de hora em hora por um LaunchAgent do macOS, num Mac onde
# ~/.claude/skills/superdb é um link para skills/superdb deste clone: assim os
# chats do Claude dessa máquina leem sempre a skill que o workflow
# sincronizar-skill trouxe do site.
#
# Nunca insiste: sem rede, conflito ou mudança local, registra uma linha no log e
# sai. Quem resolve é uma pessoa, olhando o log.
#
# Variáveis (opcionais):
#   PLUGIN_DIR  o clone (padrão: a pasta acima deste script)
#   LOG         o arquivo de log (padrão: ~/Library/Logs/superdb-sincroniza-skill.log)

PLUGIN_DIR="${PLUGIN_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
LOG="${LOG:-$HOME/Library/Logs/superdb-sincroniza-skill.log}"
mkdir -p "$(dirname "$LOG")"

# O git do Command Line Tools funciona mesmo quando o /usr/bin/git (atalho do
# Xcode) trava pedindo para aceitar a licença.
if [ -x /Library/Developer/CommandLineTools/usr/bin/git ]; then
  GIT=/Library/Developer/CommandLineTools/usr/bin/git
else
  GIT=git
fi

# Sem prompt de senha e sem pendurar numa rede ruim: abaixo de 1 KB/s por 30 s, desiste.
export GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30

agora() { date '+%Y-%m-%dT%H:%M:%S%z'; }

antes=$("$GIT" -C "$PLUGIN_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')
if saida=$("$GIT" -C "$PLUGIN_DIR" pull --ff-only --quiet 2>&1); then
  depois=$("$GIT" -C "$PLUGIN_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')
  if [ "$antes" = "$depois" ]; then
    echo "$(agora) ok sem mudança ($depois)" >> "$LOG"
  else
    echo "$(agora) ok atualizado $antes -> $depois" >> "$LOG"
  fi
else
  echo "$(agora) falhou ($antes): $(printf '%s' "$saida" | tr '\n' ' ' | cut -c1-300)" >> "$LOG"
fi
exit 0
