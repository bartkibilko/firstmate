#!/usr/bin/env bash
# Live guard for the supervision host's dialog-mirror writers
# (bin/fm-host-mirror.sh, docs/supervision-host.md "The dialog mirror"): each
# INSTALLED primary harness with a verified writer runs one real prompt in a
# fixture primary checkout that carries this repo's tracked mirror
# registrations, and the mirror must record the captain's prompt and main's
# reply. The writers read vendor hook payloads, so only the real harness can
# prove them. Opt-in because it submits prompts:
#
#   FM_HOST_MIRROR_LIVE_E2E=1 tests/fm-host-mirror-live-e2e.test.sh
#
# FM_HOST_MIRROR_LIVE_HARNESSES (default "claude codex cursor grok opencode")
# narrows the set, and FM_HOST_MIRROR_LIVE_OPENCODE_MODEL picks OpenCode's
# model (default opencode/big-pickle). An absent harness is reported, never
# passed over silently, and a run that checked no harness fails. Cursor and
# Grok fire project hooks only in an interactive session, and OpenCode's
# headless run exits before its plugin sees the session go idle, so those three
# run in a private tmux server; Claude and Codex run headless.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_HOST_MIRROR_LIVE_E2E jq tmux

HARNESSES=${FM_HOST_MIRROR_LIVE_HARNESSES:-claude codex cursor grok opencode}
OPENCODE_MODEL=${FM_HOST_MIRROR_LIVE_OPENCODE_MODEL:-opencode/big-pickle}
LAB=$(fm_test_tmproot fm-host-mirror-live)
SOCKET="fmhm-$$"
PROMPT='Reply with exactly the word mirror-ok and nothing else.'
CHECKED=0
ABSENT=

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE TMUX TMUX_PANE

# A primary checkout carrying only the tracked mirror registrations, so no
# other hook of this repo runs in it.
make_primary() {  # <name>
  local root="$LAB/$1"
  mkdir -p "$root/state" "$root/config" "$root/.claude" "$root/.codex" "$root/.cursor" "$root/.grok/hooks" "$root/.opencode/plugins"
  git init -q "$root"
  : > "$root/AGENTS.md"
  : > "$root/config/supervision-host"
  ln -s "$ROOT/bin" "$root/bin"
  jq '.hooks |= (with_entries(.value |= (map(.hooks |= map(select(.command | contains("fm-host-mirror.sh")))) | map(select(.hooks | length > 0)))) | with_entries(select(.value | length > 0))) | {hooks}' \
    "$ROOT/.claude/settings.json" > "$root/.claude/settings.json"
  jq '.hooks |= (with_entries(.value |= (map(.hooks |= map(select(.command | contains("fm-host-mirror.sh")))) | map(select(.hooks | length > 0)))) | with_entries(select(.value | length > 0))) | {hooks}' \
    "$ROOT/.codex/hooks.json" > "$root/.codex/hooks.json"
  jq '.hooks |= (with_entries(.value |= map(select(.command | contains("fm-host-mirror.sh")))) | with_entries(select(.value | length > 0)))' \
    "$ROOT/.cursor/hooks.json" > "$root/.cursor/hooks.json"
  cp "$ROOT/.grok/hooks/fm-primary-host-mirror.json" "$root/.grok/hooks/"
  cp -R "$ROOT/.opencode/plugins/lib" "$root/.opencode/plugins/"
  cp "$ROOT/.opencode/plugins/package.json" "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$root/.opencode/plugins/"
  printf '%s\n' "$root"
}

mirrored() {  # <root> <tag> <fixed text>
  jq -r --arg tag "$2" 'select(.tag == $tag) | .text' "$1/state/.host-mirror.jsonl" 2>/dev/null | grep -F -- "$3" >/dev/null
}

wait_mirrored() {  # <root> <seconds>
  local i=0
  while [ "$i" -lt "$(( $2 * 2 ))" ]; do
    mirrored "$1" captain "$PROMPT" && mirrored "$1" main mirror-ok && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

check() {  # <harness> <version> <root>
  if mirrored "$3" captain "$PROMPT" && mirrored "$3" main mirror-ok; then
    printf 'ok - %s %s: the tracked registrations mirrored the captain prompt and main reply\n' "$1" "$2"
    CHECKED=$((CHECKED + 1))
    return 0
  fi
  fail "$1 $2: the mirror did not record the captain prompt and main reply: $(cat "$3/state/.host-mirror.jsonl" 2>/dev/null)"
}

# The harness process records its own pid as the session lock, then execs the
# harness, so the lock holder is the harness that fires the hooks.
LOCKED_EXEC='printf "%s\n" "$$" > state/.lock; exec "$@"'

run_claude() {
  local root version
  version=$(claude --version 2>/dev/null | head -n 1)
  root=$(make_primary claude)
  (cd "$root" && perl -e 'alarm 300; exec @ARGV' sh -c "$LOCKED_EXEC" sh claude -p "$PROMPT" --model haiku </dev/null) \
    > "$LAB/claude.out" 2>&1 || fail "claude $version: the prompt failed: $(tail -5 "$LAB/claude.out")"
  wait_mirrored "$root" 20 || true
  check claude "$version" "$root"
}

run_codex() {
  local root version
  version=$(codex --version 2>/dev/null | head -n 1)
  root=$(make_primary codex)
  (cd "$root" && perl -e 'alarm 300; exec @ARGV' sh -c "$LOCKED_EXEC" sh codex exec --dangerously-bypass-hook-trust \
    --skip-git-repo-check -c 'model_reasoning_effort="low"' "$PROMPT" </dev/null) \
    > "$LAB/codex.out" 2>&1 || fail "codex $version: the prompt failed: $(tail -5 "$LAB/codex.out")"
  wait_mirrored "$root" 20 || true
  check codex "$version" "$root"
}

# An interactive session in a private tmux server: answer a trust prompt when
# one appears, type the prompt, and wait for the mirror.
run_interactive() {  # <harness> <command> [arguments...]
  local harness=$1 command=$2 root version i screen
  shift 2
  version=$("$command" --version 2>/dev/null | head -n 1)
  root=$(make_primary "$harness")
  tmux -L "$SOCKET" new-session -d -s "$harness" -x 200 -y 50 -c "$root" \
    "sh -c '$LOCKED_EXEC' sh $command $*" || fail "$harness $version: the tmux session did not start"
  i=0
  while [ "$i" -lt 60 ]; do
    screen=$(tmux -L "$SOCKET" capture-pane -p -t "$harness" 2>/dev/null)
    case "$screen" in
      *'[a] Trust this workspace'*) tmux -L "$SOCKET" send-keys -t "$harness" a ;;
      *'Do you trust the contents of this directory'*) tmux -L "$SOCKET" send-keys -t "$harness" y ;;
      *'Plan, search, build'*|*'Grok Build'*|*'ctrl+p'*|*'tab agents'*) break ;;
    esac
    sleep 1
    i=$((i + 1))
  done
  sleep 3
  tmux -L "$SOCKET" send-keys -t "$harness" -l "$PROMPT"
  sleep 1
  tmux -L "$SOCKET" send-keys -t "$harness" Enter
  if ! wait_mirrored "$root" 180; then
    tmux -L "$SOCKET" capture-pane -p -t "$harness" > "$LAB/$harness.screen" 2>/dev/null || true
  fi
  tmux -L "$SOCKET" kill-session -t "$harness" >/dev/null 2>&1 || true
  check "$harness" "$version" "$root"
}

for harness in $HARNESSES; do
  case "$harness" in
    claude|codex|opencode) bin=$harness ;;
    cursor) bin=cursor-agent ;;
    grok) bin=grok ;;
    *) fail "unknown harness in FM_HOST_MIRROR_LIVE_HARNESSES: $harness" ;;
  esac
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf 'absent - %s is not installed, so its mirror writer was not checked\n' "$harness"
    ABSENT="$ABSENT $harness"
    continue
  fi
  "$ROOT/bin/fm-host-mirror.sh" verified "$harness" || fail "$harness is not in the verified-writer list this guard proves"
  case "$harness" in
    claude) run_claude ;;
    codex) run_codex ;;
    opencode) run_interactive opencode opencode -m "$OPENCODE_MODEL" ;;
    cursor) run_interactive cursor cursor-agent ;;
    grok) run_interactive grok grok ;;
  esac
done

[ "$CHECKED" -gt 0 ] || fail "no installed harness was checked (absent:${ABSENT:- none})"
pass "host mirror live: $CHECKED harness(es) proved their writers${ABSENT:+; absent:$ABSENT}"
