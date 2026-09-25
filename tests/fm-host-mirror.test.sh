#!/usr/bin/env bash
# Behavior tests for the supervision host's dialog mirror (bin/fm-host-mirror.sh,
# docs/supervision-host.md "The dialog mirror"): its writers, driven through the
# tracked hook registrations each primary harness runs, and its feed.
#
# Every writer runs as a child of a fake harness (a bash symlink named
# "claude") whose pid is the home's session lock, from a git checkout that
# passes the primary-scope check, exactly as a primary's own hook runs. Hook
# payloads are the shapes measured from the real harnesses
# (docs/supervision-host.md "The dialog mirror").
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MIRROR="$ROOT/bin/fm-host-mirror.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-host-mirror)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
trap fm_test_cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR

# A primary checkout: git, AGENTS.md, and this repo's bin and hook registrations.
PRIMARY_ROOT="$TMP_ROOT/primary"
mkdir -p "$PRIMARY_ROOT"
git init -q "$PRIMARY_ROOT"
: > "$PRIMARY_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$PRIMARY_ROOT/bin"
ln -s "$ROOT/.codex" "$PRIMARY_ROOT/.codex"

make_home() {  # <name> [opted-in: 1|0]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  [ "${2:-1}" != 1 ] || : > "$home/config/supervision-host"
  printf '%s\n' "$home"
}

# Run a shell script as the lock-owning primary session of <home>: the script
# runs under the fake harness whose pid it records as the session lock.
as_session() {  # <home> <script>
  FM_HOME="$1" PRIMARY_ROOT="$PRIMARY_ROOT" MIRROR="$MIRROR" "$FAKE_CLAUDE" -c \
    'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; '"$2"
}

# The command string one tracked registration runs.
claude_cmd() { jq -r --arg e "$1" '.hooks[$e][].hooks[] | select(.command | contains("fm-host-mirror.sh")) | .command' "$ROOT/.claude/settings.json"; }
codex_cmd() { jq -r --arg e "$1" '.hooks[$e][].hooks[] | select(.command | contains("fm-host-mirror.sh")) | .command' "$ROOT/.codex/hooks.json"; }
cursor_cmd() { jq -r --arg e "$1" '.hooks[$e][] | select(.command | contains("fm-host-mirror.sh")) | .command' "$ROOT/.cursor/hooks.json"; }

# Inside an as_session script: one Claude prompt-submit (captain) or Stop
# (main) hook payload carrying <text>, through the mirror's hook writer.
SAY='say() {  # <captain|main> <text> [<id>]
  if [ "$1" = captain ]; then
    jq -cn --arg t "$2" --arg id "${3:-}" "{hook_event_name: \"UserPromptSubmit\", prompt_id: \$id, prompt: \$t}"
  else
    jq -cn --arg t "$2" --arg id "${3:-}" "{hook_event_name: \"Stop\", prompt_id: \$id, last_assistant_message: \$t}"
  fi | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude
}
'

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

entries() {  # <home> -> "<tag>|<text>" per entry
  jq -r '"\(.tag)|\(.text)"' "$1/state/.host-mirror.jsonl" 2>/dev/null
}

test_every_harness_registration_writes_the_mirror() {
  local home out
  home=$(make_home harnesses)
  CLAUDE_PROMPT=$(claude_cmd UserPromptSubmit) CLAUDE_STOP=$(claude_cmd Stop) \
  CODEX_PROMPT=$(codex_cmd UserPromptSubmit) CODEX_STOP=$(codex_cmd Stop) \
  CURSOR_PROMPT=$(cursor_cmd beforeSubmitPrompt) CURSOR_RESPONSE=$(cursor_cmd afterAgentResponse) \
  as_session "$home" '
    run() { printf "%s" "$2" | env CLAUDE_PROJECT_DIR="$PRIMARY_ROOT" CURSOR_PROJECT_DIR="$PRIMARY_ROOT" \
      bash -c "cd \"$PRIMARY_ROOT\" && $1"; }
    run "$CLAUDE_PROMPT" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt_id\":\"c1\",\"prompt\":\"claude captain\"}"
    run "$CLAUDE_STOP" "{\"hook_event_name\":\"Stop\",\"prompt_id\":\"c1\",\"last_assistant_message\":\"claude main\"}"
    run "$CODEX_PROMPT" "{\"hook_event_name\":\"UserPromptSubmit\",\"turn_id\":\"x1\",\"prompt\":\"codex captain\"}"
    run "$CODEX_STOP" "{\"hook_event_name\":\"Stop\",\"turn_id\":\"x1\",\"last_assistant_message\":\"codex main\"}"
    run "$CURSOR_PROMPT" "{\"hook_event_name\":\"beforeSubmitPrompt\",\"generation_id\":\"u1\",\"prompt\":\"cursor captain\",\"cursor_version\":\"x\"}"
    run "$CURSOR_RESPONSE" "{\"hook_event_name\":\"afterAgentResponse\",\"generation_id\":\"u1\",\"text\":\"cursor main\",\"cursor_version\":\"x\"}"
  ' || fail "a tracked mirror hook failed"
  out=$(entries "$home")
  assert_equals "captain|claude captain
main|claude main
captain|codex captain
main|codex main
captain|cursor captain
main|cursor main" "$out" "every tracked registration must write its captain prompt and main reply, in order"
  pass "mirror: the Claude, Codex, and Cursor registrations each write the captain's prompt and main's reply"
}

# A supervising Codex main stays inside one turn, so a captain message typed
# then is a mid-turn steer that only its rollout transcript records; the
# per-tool-call hook reads that transcript.
test_codex_hooks_read_the_rollout_transcript() {
  local home rollout
  home=$(make_home codex-rollout)
  rollout="$home/rollout.jsonl"
  item() {  # <role> <text>
    jq -cn --arg role "$1" --arg text "$2" \
      '{type: "response_item", payload: {type: "message", role: $role, content: [{type: (if $role == "assistant" then "output_text" else "input_text" end), text: $text}]}}'
  }
  {
    jq -cn '{type: "session_meta", payload: {}}'
    item developer 'developer instructions'
    item user '# AGENTS.md instructions for /home/fleet'
    item user '<environment_context>cwd</environment_context>'
    item user 'Dispatch the export worker.'
    item assistant 'Captain, dispatching it now.'
    jq -cn '{type: "response_item", payload: {type: "function_call", name: "exec_command"}}'
  } > "$rollout"
  ROLLOUT=$rollout CODEX_POST=$(codex_cmd PostToolUse) CODEX_STOP=$(codex_cmd Stop) as_session "$home" '
    run() { printf "%s" "$2" | bash -c "cd \"$PRIMARY_ROOT\" && $1"; }
    run "$CODEX_POST" "{\"hook_event_name\":\"PostToolUse\",\"transcript_path\":\"$ROLLOUT\"}"
    { jq -cn --arg t "Also tell me when export finishes." "{type: \"response_item\", payload: {type: \"message\", role: \"user\", content: [{type: \"input_text\", text: \$t}]}}"
      jq -cn --arg t "<hook_prompt hook_run_id=\"stop:1\">guard</hook_prompt>" "{type: \"response_item\", payload: {type: \"message\", role: \"user\", content: [{type: \"input_text\", text: \$t}]}}"
      jq -cn --arg t "Will do." "{type: \"response_item\", payload: {type: \"message\", role: \"assistant\", content: [{type: \"output_text\", text: \$t}]}}"
    } >> "$ROLLOUT"
    run "$CODEX_POST" "{\"hook_event_name\":\"PostToolUse\",\"transcript_path\":\"$ROLLOUT\"}"
    run "$CODEX_STOP" "{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$ROLLOUT\",\"last_assistant_message\":\"Will do.\"}"
  ' || fail "a Codex mirror hook failed"
  assert_equals "captain|Dispatch the export worker.
main|Captain, dispatching it now.
captain|Also tell me when export finishes.
main|Will do." "$(entries "$home")" \
    "the Codex hooks must mirror the transcript's typed prompts, steers, and replies once each, without Codex's own injected items"
  pass "mirror: Codex's hooks read its rollout transcript, so a mid-turn steer is mirrored once and injected items never are"
}

# Non-host invariance: on a home without config/supervision-host, every surface
# this rung added - each tracked mirror registration, the drain's BRANCH
# OUTCOMES, and the quiet check - prints nothing and
# leaves the home's state byte-for-byte as it was, even when the home holds an
# outcome store with an unprocessed captain row (a home that once ran a host).
test_home_without_the_flag_is_untouched() {
  local home before after drained quiet status
  home=$(make_home without-flag 0)
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict captain --summary 'PR ready' >/dev/null \
    || fail "fixture: could not record a captain outcome"
  # The fixture's own session lock is written by as_session, not by a writer.
  snapshot() { (cd "$1/state" && find . -type f ! -name .lock | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }
  before=$(snapshot "$home")
  CLAUDE_PROMPT=$(claude_cmd UserPromptSubmit) CLAUDE_STOP=$(claude_cmd Stop) \
  CODEX_PROMPT=$(codex_cmd UserPromptSubmit) CODEX_POST=$(codex_cmd PostToolUse) CODEX_STOP=$(codex_cmd Stop) \
  CURSOR_PROMPT=$(cursor_cmd beforeSubmitPrompt) CURSOR_RESPONSE=$(cursor_cmd afterAgentResponse) \
  as_session "$home" '
    run() { printf "%s" "$2" | env CLAUDE_PROJECT_DIR="$PRIMARY_ROOT" CURSOR_PROJECT_DIR="$PRIMARY_ROOT" \
      bash -c "cd \"$PRIMARY_ROOT\" && $1"; }
    for cmd in "$CLAUDE_PROMPT" "$CODEX_PROMPT" "$CURSOR_PROMPT"; do
      run "$cmd" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hello\",\"transcript_path\":\"$FM_HOME/missing.jsonl\"}"
    done
    for cmd in "$CLAUDE_STOP" "$CODEX_POST" "$CODEX_STOP" "$CURSOR_RESPONSE"; do
      run "$cmd" "{\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"hi\",\"text\":\"hi\"}"
    done
  ' > "$home/writers.out" 2>&1 || fail "a mirror registration failed on a home without the flag: $(cat "$home/writers.out")"
  [ ! -s "$home/writers.out" ] || fail "a mirror registration printed on a home without the flag: $(cat "$home/writers.out")"
  after=$(snapshot "$home")
  assert_equals "$before" "$after" "a mirror writer changed the state of a home without the flag"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "a home without the flag must drain without branch outcomes"
  assert_absent "$home/state/.branch-outcomes-cursor" "a home without the flag must keep its outcome cursor untouched"
  quiet=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" CLAUDECODE=1 "$ROOT/bin/fm-afk-launch.sh" quiet-check 2>&1)
  status=$?
  [ "$status" -ne 0 ] && [ -z "$quiet" ] || fail "the quiet check answered on a home without the flag (rc=$status): $quiet"
  pass "mirror: a home without the flag is untouched by every writer, the drain section, and the quiet check"
}

test_writers_are_inert_without_the_opt_in() {
  local home crew out
  home=$(make_home no-opt-in 0)
  as_session "$home" '
    printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hello\"}" | "$MIRROR" hook claude
  ' || fail "an inert writer failed"
  assert_absent "$home/state/.host-mirror.jsonl" "a home without config/supervision-host must mirror nothing"
  crew="$TMP_ROOT/crew-worktree"
  mkdir -p "$crew"
  out=$(printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"hello"}' | FM_HOME="$crew" "$MIRROR" hook claude 2>&1)
  [ -z "$out" ] || fail "an inert writer printed: $out"
  assert_absent "$crew/state" "an inert writer must create nothing in a home without config/"
  pass "mirror: writers stay silent and write nothing on a home that did not opt in"
}

test_operational_foreign_and_unowned_input_is_dropped() {
  local home other
  home=$(make_home dropped)
  as_session "$home" '
    printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"\342\201\243FIRSTMATE_OP: v1 watcher: signal: demo.status\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude
    printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"from cursor\",\"cursor_version\":\"x\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude
    printf "%s" "{\"hook_event_name\":\"PreToolUse\",\"prompt\":\"not dialog\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude
    printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"\\n\\n<task-notification>\\n<summary>Stop hook feedback</summary>\\n</task-notification>\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude
    printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"kept\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude
  ' || fail "a writer failed"
  assert_equals "captain|kept" "$(entries "$home")" \
    "operational input, a harness-started turn, a Cursor payload on the Claude registration, and a non-dialog event must not be mirrored"

  other=$(make_home unowned)
  sleep 30 &
  printf '%s\n' "$!" > "$other/state/.lock"
  printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"not the owner"}' \
    | FM_HOME="$other" FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$FAKE_CLAUDE" -c '"$0" hook claude' "$MIRROR"
  kill "$(cat "$other/state/.lock")" 2>/dev/null || true
  assert_absent "$other/state/.host-mirror.jsonl" "a session that does not hold the fleet lock must mirror nothing"
  pass "mirror: operational input, a harness-started turn, a foreign host's payload, other events, and a session without the lock are never mirrored"
}

test_entries_are_deduplicated_and_capped() {
  local home long text
  home=$(make_home capped)
  long=$(awk 'BEGIN { for (i = 0; i < 5000; i++) printf "x" }')
  LONG=$long as_session "$home" "$SAY"'
    for n in 1 2; do printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt_id\":\"p1\",\"prompt\":\"once\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude; done
    say main "$LONG" long
  ' || fail "a writer failed"
  [ "$(grep -c '"text":"once"' "$home/state/.host-mirror.jsonl")" -eq 1 ] || fail "an entry whose id is already recorded must not be appended again"
  text=$(jq -r 'select(.id == "long") | .text' "$home/state/.host-mirror.jsonl")
  assert_contains "$text" "[mirror truncated: 1000 characters omitted]" "a long entry must be capped with a truncation note"
  [ "${#text}" -lt 4100 ] || fail "a capped entry kept ${#text} characters"
  pass "mirror: a repeated entry is recorded once, and a long entry keeps its head and tail"
}

# A chmod on PATH that records, for the mirror, its entry count and mode just
# after the real chmod, and refuses while $FM_HOME/chmod-refuses exists.
CHMOD_SHIM="$TMP_ROOT/chmod-shim"
mkdir -p "$CHMOD_SHIM"
{
  printf '#!/usr/bin/env bash\nREAL_CHMOD=%q\n' "$(command -v chmod)"
  cat <<'SH'
file=${!#}
case "$file" in
  */.host-mirror.jsonl)
    [ ! -e "$FM_HOME/chmod-refuses" ] || exit 1
    "$REAL_CHMOD" "$@" || exit
    printf '%s %s\n' "$(wc -l < "$file" | tr -d ' ')" "$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file")" >> "$FM_HOME/chmod.log"
    ;;
  *) exec "$REAL_CHMOD" "$@" ;;
esac
SH
} > "$CHMOD_SHIM/chmod"
chmod +x "$CHMOD_SHIM/chmod"

test_mirror_is_owner_only_under_an_open_umask() {
  local home mirror
  home=$(make_home private)
  mirror="$home/state/.host-mirror.jsonl"
  (umask 022; as_session "$home" "$SAY"'say captain "keep this between us" p1') || fail "a writer failed"
  [ "$(mode_of "$mirror")" = 600 ] || fail "a new mirror must be owner-only, got $(mode_of "$mirror")"
  chmod 644 "$mirror"
  (umask 022; PATH="$CHMOD_SHIM:$PATH" as_session "$home" "$SAY"'say main "understood" p1') || fail "a writer failed"
  [ "$(cat "$home/chmod.log" 2>/dev/null)" = "1 600" ] \
    || fail "an existing readable mirror must be owner-only before new dialog lands, got: $(cat "$home/chmod.log" 2>/dev/null)"
  [ "$(mode_of "$mirror")" = 600 ] || fail "an existing readable mirror must stay owner-only, got $(mode_of "$mirror")"
  [ "$(entries "$home" | wc -l | tr -d ' ')" -eq 2 ] || fail "both entries must be recorded: $(entries "$home")"
  chmod 644 "$mirror"
  : > "$home/chmod-refuses"
  (umask 022; PATH="$CHMOD_SHIM:$PATH" as_session "$home" "$SAY"'say captain "not for other eyes" p2') || fail "a writer failed"
  [ "$(entries "$home" | wc -l | tr -d ' ')" -eq 2 ] || fail "dialog must not land in a mirror that could not be made owner-only: $(entries "$home")"
  pass "mirror: the captain's dialog lands only in an owner-only mirror, even when the file already existed readable by others"
}

# A Codex message that could not be recorded, because the existing mirror
# could not be made owner-only, is not read past: the next hook records it
# once the mirror can be restricted again.
test_codex_message_refused_by_the_mirror_is_retried() {
  local home rollout
  home=$(make_home codex-retry)
  rollout="$home/rollout.jsonl"
  item() {  # <role> <text>
    jq -cn --arg role "$1" --arg text "$2" \
      '{type: "response_item", payload: {type: "message", role: $role, content: [{type: (if $role == "assistant" then "output_text" else "input_text" end), text: $text}]}}'
  }
  post() {  # <home>
    ROLLOUT=$rollout PATH="$CHMOD_SHIM:$PATH" as_session "$1" '
      printf "%s" "{\"hook_event_name\":\"PostToolUse\",\"transcript_path\":\"$ROLLOUT\"}" \
        | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook codex
    ' || fail "a Codex mirror hook failed"
  }
  item user 'Dispatch the export worker.' > "$rollout"
  post "$home"
  item user 'Hold the merge until I say so.' >> "$rollout"
  : > "$home/chmod-refuses"
  post "$home"
  assert_equals "captain|Dispatch the export worker." "$(entries "$home")" \
    "a message must not land in a mirror that could not be made owner-only"
  rm -f "$home/chmod-refuses"
  item assistant 'Holding it.' >> "$rollout"
  post "$home"
  assert_equals "captain|Dispatch the export worker.
captain|Hold the merge until I say so.
main|Holding it." "$(entries "$home")" \
    "the next hook must record the refused message, once, ahead of what followed it"
  pass "mirror: a Codex message the mirror refused is recorded by the next hook instead of being read past"
}

test_feed_resumes_reanchors_and_is_bounded() {
  local home out
  home=$(make_home feed)
  as_session "$home" "$SAY"'
    say captain "first ask"; say main "first answer"
    "$MIRROR" feed s1 new > "$FM_HOME/feed.1" && "$MIRROR" commit
    say captain "second ask"
    "$MIRROR" feed s1 resume > "$FM_HOME/feed.uncommitted"
    "$MIRROR" feed s1 resume > "$FM_HOME/feed.2" && "$MIRROR" commit
    "$MIRROR" feed s1 resume > "$FM_HOME/feed.3" && "$MIRROR" commit
    "$MIRROR" feed s2 resume > "$FM_HOME/feed.4"
  ' || fail "the first session failed"
  assert_equals "[captain] first ask
[main] first answer" "$(cat "$home/feed.1")" "a new conversation must be fed this session's dialog"
  assert_equals "[captain] second ask" "$(cat "$home/feed.uncommitted")" "a resumed conversation must be fed only what is new"
  assert_equals "[captain] second ask" "$(cat "$home/feed.2")" "a feed never committed to the engine must leave its entries for the next feed"
  assert_equals "" "$(cat "$home/feed.3")" "a resumed conversation with nothing new must be fed nothing"
  assert_equals "[captain] first ask
[main] first answer
[captain] second ask" "$(cat "$home/feed.4")" "a conversation the cursor does not belong to must re-anchor"

  as_session "$home" "$SAY"'
    say captain "a later session"
    "$MIRROR" feed s3 new > "$FM_HOME/feed.5"
    big=$(awk "BEGIN { for (i = 0; i < 3000; i++) printf \"y\" }")
    for n in 1 2 3 4 5 6 7; do say main "$n $big"; done
    "$MIRROR" feed s4 new > "$FM_HOME/feed.6"
  ' || fail "the second session failed"
  assert_equals "[captain] a later session" "$(cat "$home/feed.5")" "a new main session must never be fed an earlier session's dialog"
  out=$(cat "$home/feed.6")
  assert_contains "$(head -n 1 "$home/feed.6")" "earlier mirrored entries are not shown)" "a bounded feed must say what it left out"
  assert_contains "$out" "[main] 7 yyy" "a bounded feed must keep the newest entries"
  assert_not_contains "$out" "[captain] a later session" "a bounded feed must drop the oldest entries"
  [ "${#out}" -le 16100 ] || fail "the feed was not bounded: ${#out} characters"
  pass "mirror: the feed resumes from its committed cursor, re-anchors on a new conversation or session, and is bounded"
}

test_recreated_mirror_continues_past_both_cursors() {
  local home
  home=$(make_home recreate)
  as_session "$home" "$SAY"'
    for n in 1 2 3 4 5; do say captain "earlier ask $n"; done
    "$MIRROR" feed s1 new > /dev/null && "$MIRROR" commit
    rm "$FM_HOME/state/.host-mirror.jsonl"
    say captain "asked after the mirror was lost"
    "$MIRROR" feed s1 resume > "$FM_HOME/feed.recreated"
    rm "$FM_HOME/state/.host-mirror.jsonl"
    say captain "asked while that turn ran"
    "$MIRROR" commit
    "$MIRROR" feed s1 resume > "$FM_HOME/feed.after-commit"
  ' || fail "the session failed"
  assert_equals "[captain] asked after the mirror was lost" "$(cat "$home/feed.recreated")" \
    "a recreated mirror must not number new dialog at or below the committed cursor"
  assert_equals "[captain] asked while that turn ran" "$(cat "$home/feed.after-commit")" \
    "a mirror recreated during a turn must not let that turn's commit skip new dialog"
  pass "mirror: a recreated mirror continues past the committed and staged cursors, so a resumed conversation still gets new dialog"
}

test_verified_writers() {
  local harness
  for harness in claude codex cursor; do
    "$MIRROR" verified "$harness" || fail "$harness must have a verified dialog mirror"
  done
  for harness in grok opencode omp kimi pi unknown; do
    ! "$MIRROR" verified "$harness" || fail "$harness must not claim a verified dialog mirror"
  done
  pass "mirror: exactly the primaries whose writers record a session from its first captain prompt report a verified mirror"
}

test_every_harness_registration_writes_the_mirror
test_codex_hooks_read_the_rollout_transcript
test_writers_are_inert_without_the_opt_in
test_home_without_the_flag_is_untouched
test_operational_foreign_and_unowned_input_is_dropped
test_entries_are_deduplicated_and_capped
test_mirror_is_owner_only_under_an_open_umask
test_codex_message_refused_by_the_mirror_is_retried
test_feed_resumes_reanchors_and_is_bounded
test_recreated_mirror_continues_past_both_cursors
test_verified_writers
