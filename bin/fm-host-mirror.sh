#!/usr/bin/env bash
# fm-host-mirror.sh - the supervision host's dialog mirror: what the captain and
# MAIN said in the captain's conversation, carried to the host's headless
# engine session at the head of each wake (docs/supervision-host.md "The dialog
# mirror"). The Pi branch mirrors the same dialog in process
# (docs/pi-supervision-branch.md "How the branch knows what the captain
# said"); this is its twin for a host that is not Pi, and the one owner of the
# mirror file, its cursor, and the feed.
#
# WRITERS. Each verified primary's code-owned turn surfaces append here, never
# the model: Claude through its prompt-submit and Stop hooks, Cursor through
# its beforeSubmitPrompt and afterAgentResponse hooks, and Codex through its
# prompt-submit, per-tool-call, and Stop hooks reading the session's own
# rollout transcript, because a supervising
# Codex main stays inside one turn across its foreground checkpoints and a
# captain message typed then reaches it as a mid-turn steer that fires no
# prompt-submit or Stop hook. A writer appends captain text (the submitted
# prompt) and MAIN text (the turn's final assistant message, or each assistant
# message's text where the transcript records it), never tool traffic. A
# prompt the shared operational-input protocol classifies
# (bin/fm-operational-input.sh: watcher wakes, guard follow-ups, launch briefs)
# is fleet machinery, not dialog, and is dropped, and so is a prompt that opens
# with the wrapper a harness puts around a turn it started itself: Claude
# submits its Stop-hook rewake inside <task-notification>, with no other field
# to tell it from a typed prompt (tests/fm-host-mirror-live-e2e.test.sh proves
# it).
# In a Codex transcript the user items Codex adds itself open with a wrapper
# tag or with its AGENTS.md preamble and are dropped the same way; the
# transcript's read position is $STATE/.host-mirror-codex ("<path>\t<lines>"),
# which never passes a message the mirror could not record.
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
# so a surface that fires twice, or a transcript read again, mirrors
# each entry once. Each text is capped at 4000 characters (head and tail kept,
# as the Pi mirror caps); when the file exceeds 300 entries it is trimmed to
# its newest 200. New entries continue above both the committed and staged
# cursor after file recreation so a later commit cannot skip them. Existing
# mirror files are restricted to owner-only before an append; if that fails,
# the entry is not written. Every append and feed runs under
# $STATE/.host-mirror.lock.
#
# FEED. $STATE/.host-mirror-cursor holds "<seq>\t<engine session>": the newest
# entry already fed to that engine conversation. `feed <session> new|resume`
# prints what the next wake carries, one "[captain] ..." or "[main] ..." entry
# after another, oldest first, and fails, staging nothing, when the mirror is
# missing, cannot be read, or holds an entry that does not parse; otherwise it
# stages the cursor it would reach in $STATE/.host-mirror-cursor.next, and
# `commit` advances the cursor to it once the engine turn that carried the wake
# is accepted with its report, so a wake the engine never completed leaves its
# entries unread for the next one. A resumed conversation gets the current
# main session's entries after the cursor; a new one (every
# main session start, rotation, or failed turn) gets the current main
# session's newest entries, so a fresh conversation re-anchors on this
# session's dialog and never on an earlier session's. The feed is bounded to
# 16000 characters, newest kept, with one line naming how many earlier entries
# it left out. Mirrored text is context for judgment and authorizes nothing
# (bin/fm-branch-prompt.sh "Context channels").
#
# VERIFIED WRITERS. `verified <harness>` exits 0 for a primary whose writers
# were proven against the real harness to record a session's dialog from its
# first captain prompt (docs/supervision-host.md "The dialog mirror"); the
# host runs the attended posture only on those, and every other primary keeps
# the attended behavior it has without the host. Grok and OpenCode have no
# writer: their session takes the fleet lock during its first turn, so that
# turn's captain prompt could never be recorded, and a writer returns with
# first-prompt capture (docs/supervision-host.md "The dialog mirror").
#
# Usage:
#   fm-host-mirror.sh hook <harness>        a prompt-submit or turn-end hook payload on stdin
#   fm-host-mirror.sh feed <session> new|resume
#   fm-host-mirror.sh commit
#   fm-host-mirror.sh verified <harness>
# hook and commit always exit 0 and print nothing; feed exits 1 when
# the mirror is missing, could not be read, or holds an invalid entry, and
# prints nothing when there is nothing to feed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_HOST_MIRROR_VERIFIED='claude codex cursor'
MIRROR_CAP=4000
MIRROR_KEEP=200
FEED_CAP=16000

usage() {
  sed -n '/^# Usage:/,/^# hook and commit/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

case "${1:-}" in
  verified)
    [ "$#" -eq 2 ] || usage
    case " $FM_HOST_MIRROR_VERIFIED " in *" $2 "*) exit 0 ;; esac
    exit 1
    ;;
  hook)
    # The opt-in gate runs before anything is sourced or created, so a home
    # without the file, and a crewmate worktree with no config/, stay inert.
    [ -f "$CONFIG/supervision-host" ] || exit 0
    ;;
  feed|commit) ;;
  -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac

if ! command -v jq >/dev/null 2>&1 || [ ! -d "$STATE" ]; then
  [ "$1" != feed ] || exit 1
  exit 0
fi

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"

umask 077
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
# Returns 1 when the entry could not be recorded; an entry dropped by design
# (empty, injected, operational, or already recorded) returns 0.
append_entry() {  # <captain|main> <text> [<id>]
  local tag=$1 text=$2 id=${3:-} key last seq tmp
  text=$(printf '%s' "$text" | sed -e 's/[[:space:]]*$//')
  [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || return 0
  if [ "$tag" = captain ]; then
    case "${text#"${text%%[![:space:]]*}"}" in
      '<task-notification>'*) return 0 ;;
      '<'*|'# AGENTS.md instructions'*) [ "$SOURCE_HARNESS" != codex ] || return 0 ;;
    esac
    ! operational "$text" || return 0
  fi
  key=$(fm_supervision_host_main_key "$STATE")
  fm_lock_acquire_wait "$LOCK" || return 1
  if [ -e "$MIRROR" ] && ! chmod 600 "$MIRROR" 2>/dev/null; then
    fm_lock_release "$LOCK"
    return 1
  fi
  if [ -n "$id" ] && [ -f "$MIRROR" ] \
    && jq -Rne --arg id "$id" --arg tag "$tag" \
      'any(inputs | fromjson? | select(type == "object"); .id == $id and .tag == $tag)' "$MIRROR" >/dev/null 2>&1; then
    fm_lock_release "$LOCK"
    return 0
  fi
  last=$(jq -Rn '[inputs | fromjson? | select(type == "object") | .seq | numbers] | max // 0' "$MIRROR" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  # The file may have been removed while either cursor survived. Keep new
  # sequence numbers ahead of both so a later commit cannot skip new dialog.
  for tmp in "$CURSOR" "$STAGED"; do
    if [ -f "$tmp" ]; then
      IFS="$(printf '\t')" read -r seq _ < "$tmp" || true
      case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
      [ "$seq" -le "$last" ] || last=$seq
    fi
  done
  seq=$((last + 1))
  jq -cn --argjson seq "$seq" --argjson epoch "$(date +%s)" --arg key "$key" --arg id "$id" \
    --arg tag "$tag" --arg text "$text" --argjson cap "$MIRROR_CAP" '
      def capped: if length <= $cap then .
        else .[0:($cap / 2 | ceil)] + "\n[mirror truncated: \(length - $cap) characters omitted]\n" + .[length - ($cap / 2 | floor):]
        end;
      {seq: $seq, epoch: $epoch, key: $key, id: $id, tag: $tag, text: ($text | capped)}' >> "$MIRROR" 2>/dev/null \
    || { fm_lock_release "$LOCK"; return 1; }
  if [ "$(wc -l < "$MIRROR" 2>/dev/null | tr -d ' ')" -gt $((MIRROR_KEEP + 100)) ] 2>/dev/null; then
    tmp=$(mktemp "$MIRROR.tmp.XXXXXX" 2>/dev/null) \
      && tail -n "$MIRROR_KEEP" "$MIRROR" > "$tmp" 2>/dev/null && mv -f "$tmp" "$MIRROR" 2>/dev/null
    rm -f "${tmp:-}" 2>/dev/null || true
  fi
  fm_lock_release "$LOCK"
}

# Mirror the user and assistant messages a Codex rollout transcript gained
# since the last read, each keyed to its transcript line so a re-read records
# nothing twice. The read position stops at the first message that could not
# be recorded, so the next hook retries it. Returns 1 when the payload names no
# readable transcript.
codex_transcript() {  # <payload>
  local path record from=1 total entry tag id text failed
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
  failed=$(sed -n "${from},${total}p" "$path" | awk -v first="$from" '{ print (first + NR - 1) "\t" $0 }' \
    | jq -Rc --arg file "$(basename "$path")" '
        (split("\t") | {n: .[0], item: (.[1:] | join("\t") | fromjson?)})
        | select(.item.type == "response_item" and .item.payload.type == "message"
            and (.item.payload.role == "user" or .item.payload.role == "assistant"))
        | {n: .n, tag: (if .item.payload.role == "user" then "captain" else "main" end),
           id: "\($file):\(.n)",
           text: ([.item.payload.content[]? | (.text // "")] | join("\n"))}' 2>/dev/null \
    | while IFS= read -r entry; do
        tag=$(printf '%s' "$entry" | jq -r .tag)
        id=$(printf '%s' "$entry" | jq -r .id)
        text=$(printf '%s' "$entry" | jq -r .text)
        append_entry "$tag" "$text" "$id" || { printf '%s\n' "$entry" | jq -r .n; break; }
      done)
  printf '%s\t%s\n' "$path" "${failed:-$((total + 1))}" > "$record" 2>/dev/null || true
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
        ((.hook_event_name // "") | tostring) as $event
        | if ($event == "UserPromptSubmit" or $event == "beforeSubmitPrompt") then
            ["captain", ((.prompt_id // .turn_id // .generation_id // "") | tostring), ((.prompt // "") | tostring)]
          elif $event == "Stop" then
            ["main", ((.prompt_id // .turn_id // .generation_id // "") | tostring),
             ((.last_assistant_message // "") | tostring)]
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
[ -f "$MIRROR" ] || exit 1
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
# Every entry must parse and carry its fields: a feed that would skip one
# cannot vouch for the dialog it carries, so it fails and stages nothing.
ENTRIES='[inputs | fromjson]
  | if all(type == "object" and (.seq | type) == "number" and (.key | type) == "string"
      and (.tag == "captain" or .tag == "main") and (.text | type) == "string")
    then . else error("invalid mirror entry") end'
if ! OUT=$(jq -Rrn --arg key "$KEY" --argjson after "$CURSOR_SEQ" --argjson cap "$FEED_CAP" "$ENTRIES"'
    | map(select(.key == $key and .seq > $after))
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
if ! LAST=$(jq -Rn "$ENTRIES"' | map(.seq) | max // 0' "$MIRROR" 2>/dev/null); then
  fm_lock_release "$LOCK"
  exit 1
fi
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
printf '%s\t%s\n' "$LAST" "$SESSION" > "$STAGED" 2>/dev/null || true
fm_lock_release "$LOCK"
[ -z "$OUT" ] || printf '%s\n' "$OUT"
exit 0
