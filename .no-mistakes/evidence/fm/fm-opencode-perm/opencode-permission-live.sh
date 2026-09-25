#!/usr/bin/env bash
# Live: real OpenCode 1.18.32 TUI inside a guarded Herdr lab session, in a project
# whose committed opencode.json asks for everything. Compares the pre-change launch env
# (OPENCODE_CONFIG_CONTENT) with the env emitted by fm-spawn's real launch_template.
set -u
ROOT=${ROOT:?}; E=${E:?}; MODEL=${MODEL:-openai/gpt-5.4-mini}
LAB="$ROOT/bin/fm-herdr-lab.sh"
S=$("$LAB" name fm-oc-perm) || exit 1
trap '"$LAB" teardown "$S"' EXIT
"$LAB" provision "$S" || exit 1
lab() { "$LAB" run "$S" "$@"; }
. "$ROOT/bin/backends/herdr.sh"
fm_backend_herdr_cli() { shift; lab "$@"; }

NEW_ENV=$(bash -c 'source <(sed -n "/^launch_template() {/,/^}/p" "$0/bin/fm-spawn.sh"); launch_template opencode ship' "$ROOT" | sed -n "s/^\(OPENCODE_PERMISSION='[^']*'\) opencode .*/\1/p")
OLD_ENV="OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}'"
[ -n "$NEW_ENV" ] || { echo "no env from launch_template"; exit 1; }

mkproj() {  # <dir>
  mkdir -p "$1/proj" "$1/outside"; cd "$1/proj" && git init -q && cat > opencode.json <<'J'
{"$schema":"https://opencode.ai/config.json","permission":{"*":"ask","edit":"ask","external_directory":"ask","bash":{"*":"ask","git *":"ask"}}}
J
  git add -A && git -c user.email=t@t -c user.name=t commit -qm init; cd - >/dev/null
}

run_case() {  # <label> <envprefix>
  local label=$1 envp=$2 d out created pane i
  d=$(mktemp -d "${TMPDIR:-/tmp}/fm-oc-perm-$label.XXXX"); mkproj "$d"
  prompt="Do exactly these three steps with your tools, no questions: 1) run the shell command: echo bash-ok > bash.txt  2) use your edit/write file tool to create edit.txt containing edit-ok  3) use your write tool to create the file $d/outside/report.txt containing report-ok. Then reply DONE."
  echo "== $label: env = $envp"
  echo "== resolved permission (opencode debug config in project):"
  (cd "$d/proj" && eval "$envp opencode debug config" 2>/dev/null | jq -c '.permission')
  created=$(lab workspace create --cwd "$d/proj" --label "oc-$label" --no-focus)
  pane=$(printf '%s' "$created" | jq -er '.result.root_pane.pane_id')
  lab pane run "$pane" "$envp opencode --model $MODEL --prompt '$prompt'" >/dev/null
  for i in $(seq 1 120); do
    [ -f "$d/proj/bash.txt" ] && [ -f "$d/proj/edit.txt" ] && [ -f "$d/outside/report.txt" ] && break
    sleep 1
  done
  sleep 5
  lab pane read "$pane" --source visible > "$E/pane-$label.txt" 2>/dev/null
  echo "== files after ${i}s:"
  for f in proj/bash.txt proj/edit.txt outside/report.txt; do
    if [ -f "$d/$f" ]; then echo "  $f: $(cat "$d/$f")"; else echo "  $f: MISSING"; fi
  done
  echo "== permission prompt visible in pane: $(grep -ciE 'permission required|allow once|always allow|Reject' "$E/pane-$label.txt")"
  if [ "$label" = new ]; then
    for i in $(seq 1 60); do
      st=$(lab agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
      [ "$st" = idle ] || [ "$st" = done ] && break; sleep 1
    done
    echo "== after completed turn: herdr agent_status=$st composer_state=$(fm_backend_herdr_composer_state "$S:$pane")"
    lab pane read "$pane" --source visible > "$E/pane-new-idle-after-turn.txt" 2>/dev/null
    lab pane read "$pane" --source recent --lines 20 --format ansi > "$E/pane-new-idle-after-turn.ansi" 2>/dev/null
    lab pane send-text "$pane" "please also summarise" >/dev/null; sleep 2
    echo "== after typing an unsent draft: composer_state=$(fm_backend_herdr_composer_state "$S:$pane")"
    lab pane read "$pane" --source visible > "$E/pane-new-draft.txt" 2>/dev/null
  fi
}
run_case old "$OLD_ENV"
run_case new "$NEW_ENV"
