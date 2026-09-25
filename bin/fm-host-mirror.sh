#!/usr/bin/env bash
# fm-host-mirror.sh - the supervision host's dialog mirror: what the captain and
# MAIN said in the captain's conversation, carried to the host's headless
# engine session at the head of each wake (docs/supervision-host.md "The dialog
# mirror"). The Pi branch mirrors the same dialog in process
# (docs/pi-supervision-branch.md "How the branch knows what the captain
# said"); this is its twin for a host that is not Pi, and the one owner of the
# mirror file, its cursor, and the feed.
#
# WRITERS. Each primary's code-owned turn surfaces append here, never the
# model: Claude and Grok through their prompt-submit and Stop hooks, Cursor
# through its beforeSubmitPrompt and afterAgentResponse hooks, OpenCode through
# its TUI plugin, and Codex through its prompt-submit, per-tool-call, and Stop
# hooks reading the session's own rollout transcript, because a supervising
# Codex main stays inside one turn across its foreground checkpoints and a
# captain message typed then reaches it as a mid-turn steer that fires no
# prompt-submit or Stop hook. A writer appends captain text (the submitted
# prompt) and MAIN text (the turn's final assistant message, or each assistant
# message's text where the surface sees messages), never tool traffic. A
# prompt the shared operational-input protocol classifies
# (bin/fm-operational-input.sh: watcher wakes, guard follow-ups, launch briefs)
# is fleet machinery, not dialog, and is dropped, and so is a prompt that opens
# with the wrapper a harness puts around a turn it started itself: Claude
# submits its Stop-hook rewake inside <task-notification>, and Grok its
# background-task completion inside <system-reminder>, each with no other field
# to tell it from a typed prompt (tests/fm-host-mirror-live-e2e.test.sh proves
# both).
# In a Codex transcript the user items Codex adds itself open with a wrapper
# tag or with its AGENTS.md preamble and are dropped the same way; the
# transcript's read position is $STATE/.host-mirror-codex ("<path>\t<lines>").
# Every writer is a silent no-op unless this home opted into the supervision
# host (config/supervision-host, checked before anything else runs), the hook
# runs in a genuine primary checkout, and this session holds the fleet lock, so
# a home without the file, a crewmate worktree, and a read-only second session
# write nothing and print nothing.
#
# FILE. $STATE/.host-mirror.jsonl, one JSON object per line:
#   {"seq":N,"epoch":N,"key":"<main session>","id":"<source id>",
#    "tag":"captain"|"main","text":"..."}
# key is the main-session key the host keys its engine conversation to
# (fm_supervision_host_main_key, bin/fm-supervision-engine-lib.sh). id is the
# writer's own identity for the entry when it has one (a prompt id, a turn id,
# a message id); an entry whose id is already recorded is not appended again,
# so a surface that fires twice, or a plugin that re-reads its session, mirrors
# each entry once. Each text is capped at 4000 characters (head and tail kept,
# as the Pi mirror caps), and the file keeps its newest 200 entries. Every
# append and feed runs under $STATE/.host-mirror.lock.
#
# FEED. $STATE/.host-mirror-cursor holds "<seq>\t<engine session>": the newest
# entry already fed to that engine conversation. `feed <session> new|resume`
# prints what the next wake carries, one "[captain] ..." or "[main] ..." entry
# after another, oldest first, and stages the cursor it would reach in
# $STATE/.host-mirror-cursor.next; `commit` advances the cursor to it once the
# wake is handed to the engine, so a wake that never reaches the engine leaves
# its entries unread for the next one. A resumed conversation
# gets the current main session's entries after the cursor; a new one (every
# main session start, rotation, or failed turn) gets the current main
# session's newest entries, so a fresh conversation re-anchors on this
# session's dialog and never on an earlier session's. The feed is bounded to
# 16000 characters, newest kept, with one line naming how many earlier entries
# it left out. Mirrored text is context for judgment and authorizes nothing
# (bin/fm-branch-prompt.sh "Context channels").
#
# VERIFIED WRITERS. `verified <harness>` exits 0 for a primary whose writers
# were proven against the real harness (docs/supervision-host.md "The dialog
# mirror"); the host runs the attended posture only on those, and every other
# primary keeps the attended behavior it has without the host.
#
# Usage:
#   fm-host-mirror.sh hook <harness>        a prompt-submit or turn-end hook payload on stdin
#   fm-host-mirror.sh append captain|main [--id <id>]
#                                           one entry's text on stdin (plugin writers)
#   fm-host-mirror.sh feed <session> new|resume
#   fm-host-mirror.sh commit
#   fm-host-mirror.sh verified <harness>
# hook, append, and commit always exit 0 and print nothing; feed exits 1 when
# the mirror could not be read, and prints nothing when there is nothing to
# feed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_HOST_MIRROR_VERIFIED='claude codex cursor grok opencode'
MIRROR_CAP=4000
MIRROR_KEEP=200
FEED_CAP=16000

usage() {
  sed -n '/^# Usage:/,/^# hook and append/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

case "${1:-}" in
  verified)
    [ "$#" -eq 2 ] || usage
    case " $FM_HOST_MIRROR_VERIFIED " in *" $2 "*) exit 0 ;; esac
    exit 1
    ;;
  hook|append)
    # The opt-in gate runs before anything is sourced or created, so a home
    # without the file, and a crewmate worktree with no config/, stay inert.
    [ -f "$CONFIG/supervision-host" ] || exit 0
    ;;
  feed|commit) ;;
  -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac

command -v jq >/dev/null 2>&1 || exit 0
[ -d "$STATE" ] || exit 0

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"

MIRROR="$STATE/.host-mirror.jsonl"
CURSOR="$STATE/.host-mirror-cursor"
STAGED="$CURSOR.next"
LOCK="$STATE/.host-mirror.lock"

# A writer records only the lock-owning primary session's dialog.
writer_in_scope() {
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" && fm_session_lock_owned_by_self "$STATE"
}

operational() {  # <text>
  printf '%s' "$1" | "$SCRIPT_DIR/fm-operational-input.sh" classify >/dev/null 2>&1
}

# Append one entry. The caller holds nothing; this takes the mirror lock.
append_entry() {  # <captain|main> <text> [<id>]
  local tag=$1 text=$2 id=${3:-} key last seq tmp
  text=$(printf '%s' "$text" | sed -e 's/[[:space:]]*$//')
  [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || return 0
  if [ "$tag" = captain ]; then
    case "${text#"${text%%[![:space:]]*}"}" in
      '<task-notification>'*|'<system-reminder>'*) return 0 ;;
      '<'*|'# AGENTS.md instructions'*) [ "$SOURCE_HARNESS" != codex ] || return 0 ;;
    esac
    ! operational "$text" || return 0
  fi
  key=$(fm_supervision_host_main_key "$STATE")
  fm_lock_acquire_wait "$LOCK" || return 0
  if [ -n "$id" ] && [ -f "$MIRROR" ] \
    && jq -Rne --arg id "$id" --arg tag "$tag" \
      'any(inputs | fromjson? | select(type == "object"); .id == $id and .tag == $tag)' "$MIRROR" >/dev/null 2>&1; then
    fm_lock_release "$LOCK"
    return 0
  fi
  last=$(jq -Rn '[inputs | fromjson? | select(type == "object") | .seq | numbers] | max // 0' "$MIRROR" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  seq=$((last + 1))
  jq -cn --argjson seq "$seq" --argjson epoch "$(date +%s)" --arg key "$key" --arg id "$id" \
    --arg tag "$tag" --arg text "$text" --argjson cap "$MIRROR_CAP" '
      def capped: if length <= $cap then .
        else .[0:($cap / 2 | ceil)] + "\n[mirror truncated: \(length - $cap) characters omitted]\n" + .[length - ($cap / 2 | floor):]
        end;
      {seq: $seq, epoch: $epoch, key: $key, id: $id, tag: $tag, text: ($text | capped)}' >> "$MIRROR" 2>/dev/null
  if [ "$(wc -l < "$MIRROR" 2>/dev/null | tr -d ' ')" -gt $((MIRROR_KEEP + 100)) ] 2>/dev/null; then
    tmp=$(mktemp "$MIRROR.tmp.XXXXXX" 2>/dev/null) \
      && tail -n "$MIRROR_KEEP" "$MIRROR" > "$tmp" 2>/dev/null && mv -f "$tmp" "$MIRROR" 2>/dev/null
    rm -f "${tmp:-}" 2>/dev/null || true
  fi
  fm_lock_release "$LOCK"
}

# Mirror the user and assistant messages a Codex rollout transcript gained
# since the last read, each keyed to its transcript line so a re-read records
# nothing twice. Returns 1 when the payload names no readable transcript.
codex_transcript() {  # <payload>
  local path record from=1 total entry tag id text
  path=$(printf '%s' "$1" | jq -r '.transcript_path // empty' 2>/dev/null)
  [ -n "$path" ] && [ -f "$path" ] && [ -r "$path" ] || return 1
  record="$STATE/.host-mirror-codex"
  if [ "$(cut -f1 "$record" 2>/dev/null)" = "$path" ]; then
    from=$(cut -f2 "$record" 2>/dev/null)
    case "$from" in ''|*[!0-9]*) from=1 ;; esac
  fi
  total=$(wc -l < "$path" | tr -d ' ')
  case "$total" in ''|*[!0-9]*) return 0 ;; esac
  [ "$from" -le "$((total + 1))" ] || from=1
  [ "$from" -le "$total" ] || return 0
  sed -n "${from},${total}p" "$path" | awk -v first="$from" '{ print (first + NR - 1) "\t" $0 }' \
    | jq -Rc --arg file "$(basename "$path")" '
        (split("\t") | {n: .[0], item: (.[1:] | join("\t") | fromjson?)})
        | select(.item.type == "response_item" and .item.payload.type == "message"
            and (.item.payload.role == "user" or .item.payload.role == "assistant"))
        | {tag: (if .item.payload.role == "user" then "captain" else "main" end),
           id: "\($file):\(.n)",
           text: ([.item.payload.content[]? | (.text // "")] | join("\n"))}' 2>/dev/null \
    | while IFS= read -r entry; do
        tag=$(printf '%s' "$entry" | jq -r .tag)
        id=$(printf '%s' "$entry" | jq -r .id)
        text=$(printf '%s' "$entry" | jq -r .text)
        append_entry "$tag" "$text" "$id"
      done
  printf '%s\t%s\n' "$path" "$((total + 1))" > "$record" 2>/dev/null || true
}

SOURCE_HARNESS=
case "$1" in
  hook)
    [ "$#" -eq 2 ] || exit 0
    SOURCE_HARNESS=$2
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    if [ "$2" = codex ]; then
      writer_in_scope || exit 0
      codex_transcript "$PAYLOAD" && exit 0
    fi
    if [ "$2" = claude ]; then
      # shellcheck source=bin/fm-hook-host-lib.sh
      . "$SCRIPT_DIR/fm-hook-host-lib.sh"
      # Cursor loads the tracked Claude settings too; its own entries mirror it.
      fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
    fi
    # One line per field: event, tag, id; the text follows as the remainder.
    PARSED=$(printf '%s' "$PAYLOAD" | jq -r '
      if type != "object" then empty else
        ((.hook_event_name // .hookEventName // "") | tostring) as $event
        | if ($event == "UserPromptSubmit" or $event == "user_prompt_submit" or $event == "beforeSubmitPrompt") then
            ["captain", ((.prompt_id // .promptId // .turn_id // .generation_id // "") | tostring), ((.prompt // "") | tostring)]
          elif ($event == "Stop" or $event == "stop") then
            ["main", ((.prompt_id // .promptId // .turn_id // .generation_id // "") | tostring),
             ((.last_assistant_message // .lastAssistantMessage // "") | tostring)]
          elif $event == "afterAgentResponse" then
            ["main", ((.generation_id // "") | tostring), ((.text // "") | tostring)]
          else empty end
        | select(.[2] != "")
        | "\(.[0])\n\(.[1])\n\(.[2])"
      end' 2>/dev/null) || exit 0
    [ -n "$PARSED" ] || exit 0
    TAG=$(printf '%s\n' "$PARSED" | sed -n '1p')
    ID=$(printf '%s\n' "$PARSED" | sed -n '2p')
    TEXT=$(printf '%s\n' "$PARSED" | sed '1,2d')
    writer_in_scope || exit 0
    append_entry "$TAG" "$TEXT" "$ID"
    exit 0
    ;;
  append)
    TAG=${2:-}
    case "$TAG" in captain|main) ;; *) exit 0 ;; esac
    ID=
    [ "${3:-}" != --id ] || ID=${4:-}
    TEXT=$(cat 2>/dev/null || true)
    writer_in_scope || exit 0
    append_entry "$TAG" "$TEXT" "$ID"
    exit 0
    ;;
  commit)
    [ "$#" -eq 1 ] || usage
    [ -f "$STAGED" ] || exit 0
    fm_lock_acquire_wait "$LOCK" || exit 0
    mv -f "$STAGED" "$CURSOR" 2>/dev/null || true
    fm_lock_release "$LOCK"
    exit 0
    ;;
esac

# feed <session> new|resume
[ "$#" -eq 3 ] || usage
SESSION=$2
MODE=$3
case "$MODE" in new|resume) ;; *) usage ;; esac
rm -f "$STAGED"
[ -f "$MIRROR" ] || exit 0
KEY=$(fm_supervision_host_main_key "$STATE")
fm_lock_acquire_wait "$LOCK" || exit 1
CURSOR_SEQ=0
CURSOR_SESSION=
if [ -f "$CURSOR" ]; then
  IFS="$(printf '\t')" read -r CURSOR_SEQ CURSOR_SESSION < "$CURSOR" || true
  case "$CURSOR_SEQ" in ''|*[!0-9]*) CURSOR_SEQ=0 ;; esac
fi
# A cursor that belongs to another conversation proves nothing about this one.
if [ "$MODE" = new ] || [ "$CURSOR_SESSION" != "$SESSION" ]; then
  CURSOR_SEQ=0
fi
if ! OUT=$(jq -Rrn --arg key "$KEY" --argjson after "$CURSOR_SEQ" --argjson cap "$FEED_CAP" '
    [inputs | fromjson? | select(type == "object" and .key == $key and (.seq | type) == "number" and .seq > $after
      and (.tag == "captain" or .tag == "main") and (.text | type) == "string")]
    | map("[\(.tag)] \(.text)")
    | reverse
    | reduce .[] as $entry ({kept: [], used: 0, left: 0};
        if .left == 0 and (.used + ($entry | length) + 1) <= $cap then
          .kept += [$entry] | .used += (($entry | length) + 1)
        else .left += 1 end)
    | (.kept | reverse) as $kept
    | (if .left > 0 then ["(\(.left) earlier mirrored entries are not shown)"] else [] end) + $kept
    | .[]' "$MIRROR" 2>/dev/null); then
  fm_lock_release "$LOCK"
  exit 1
fi
LAST=$(jq -Rn '[inputs | fromjson? | select(type == "object") | .seq | numbers] | max // 0' "$MIRROR" 2>/dev/null)
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
printf '%s\t%s\n' "$LAST" "$SESSION" > "$STAGED" 2>/dev/null || true
fm_lock_release "$LOCK"
[ -z "$OUT" ] || printf '%s\n' "$OUT"
exit 0
