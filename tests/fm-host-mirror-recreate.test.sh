#!/usr/bin/env bash
# A surviving engine cursor must not hide dialog appended after mirror recreation.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo 'skip: jq absent'; exit 0; }
TMP=$(mktemp -d "$ROOT/.mirror-recreate.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/config" "$TMP/bin"
: > "$TMP/config/supervision-host"
ln -s /bin/bash "$TMP/bin/claude"
# The checkout is a linked gate worktree. Simulate the plain primary checkout's
# git-dir response without creating an AGENTS.md fixture or changing the checkout.
cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = -C ] && [ "$2" = "$FM_ROOT_OVERRIDE" ] && [ "$3" = rev-parse ]; then
  case "$4" in --git-dir|--git-common-dir) echo .git; exit 0 ;; esac
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$TMP/bin/git"
REAL_GIT=$(command -v git)
export REAL_GIT
export FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP" FM_STATE_OVERRIDE="$TMP/state" FM_CONFIG_OVERRIDE="$TMP/config"
export PATH="$TMP/bin:$PATH"
# The fake harness owns the lock and delivers two hook payloads, with a
# committed feed followed by deletion/recreation of the mirror file.
# shellcheck disable=SC2016 # Variables expand in the child shell, not this test shell.
"$TMP/bin/claude" -c '
  set -eu
  printf "%s\n" "$$" > "$FM_STATE_OVERRIDE/.lock"
  say() {
    jq -cn --arg t "$1" "{hook_event_name:\"UserPromptSubmit\",prompt:\$t}" \
      | "$FM_ROOT_OVERRIDE/bin/fm-host-mirror.sh" hook claude
  }
  for n in 1 2 3 4 5; do say "earlier dialog $n"; done
  "$FM_ROOT_OVERRIDE/bin/fm-host-mirror.sh" feed engine new > "$FM_HOME/first-feed"
  "$FM_ROOT_OVERRIDE/bin/fm-host-mirror.sh" commit
  old=$(cut -f1 "$FM_STATE_OVERRIDE/.host-mirror-cursor")
  [ "$old" = 5 ] || { echo "fixture cursor is not 5: $old" >&2; exit 1; }
  rm "$FM_STATE_OVERRIDE/.host-mirror.jsonl"
  say "dialog after recreation"
  new=$(jq -r .seq "$FM_STATE_OVERRIDE/.host-mirror.jsonl")
  [ "$new" -gt "$old" ] || { echo "sequence restarted: $new <= $old" >&2; exit 1; }
  "$FM_ROOT_OVERRIDE/bin/fm-host-mirror.sh" feed engine resume > "$FM_HOME/resumed-feed"
  [ "$(cat "$FM_HOME/resumed-feed")" = "[captain] dialog after recreation" ] || {
    echo "recreated captain dialog missing from resumed feed" >&2; exit 1;
  }
  # The feed is now staged but the engine has not accepted the turn. If the
  # mirror is recreated here, the eventual commit must not skip new dialog.
  staged=$(cut -f1 "$FM_STATE_OVERRIDE/.host-mirror-cursor.next")
  rm "$FM_STATE_OVERRIDE/.host-mirror.jsonl"
  say "dialog during staged turn"
  new=$(jq -r .seq "$FM_STATE_OVERRIDE/.host-mirror.jsonl")
  [ "$new" -gt "$staged" ] || { echo "sequence restarted: $new <= staged $staged" >&2; exit 1; }
  "$FM_ROOT_OVERRIDE/bin/fm-host-mirror.sh" commit
  "$FM_ROOT_OVERRIDE/bin/fm-host-mirror.sh" feed engine resume > "$FM_HOME/after-staged-feed"
  [ "$(cat "$FM_HOME/after-staged-feed")" = "[captain] dialog during staged turn" ] || {
    echo "dialog appended during staged turn missing after commit" >&2; exit 1;
  }
' || exit 1
echo 'ok - recreated mirror continues past committed and staged engine cursors'
