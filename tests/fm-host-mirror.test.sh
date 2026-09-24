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
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR \
  GROK_WORKSPACE_ROOT GROK_AGENT GROK_HOOK_EVENT GROK_HOOK_NAME GROK_SESSION_ID

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
grok_cmd() { jq -r --arg e "$1" '.hooks[$e][].hooks[].command' "$ROOT/.grok/hooks/fm-primary-host-mirror.json"; }
cursor_cmd() { jq -r --arg e "$1" '.hooks[$e][] | select(.command | contains("fm-host-mirror.sh")) | .command' "$ROOT/.cursor/hooks.json"; }

entries() {  # <home> -> "<tag>|<text>" per entry
  jq -r '"\(.tag)|\(.text)"' "$1/state/.host-mirror.jsonl" 2>/dev/null
}

test_every_harness_registration_writes_the_mirror() {
  local home out
  home=$(make_home harnesses)
  CLAUDE_PROMPT=$(claude_cmd UserPromptSubmit) CLAUDE_STOP=$(claude_cmd Stop) \
  CODEX_PROMPT=$(codex_cmd UserPromptSubmit) CODEX_STOP=$(codex_cmd Stop) \
  GROK_PROMPT=$(grok_cmd UserPromptSubmit) GROK_STOP=$(grok_cmd Stop) \
  CURSOR_PROMPT=$(cursor_cmd beforeSubmitPrompt) CURSOR_RESPONSE=$(cursor_cmd afterAgentResponse) \
  as_session "$home" '
    run() { printf "%s" "$2" | env CLAUDE_PROJECT_DIR="$PRIMARY_ROOT" CURSOR_PROJECT_DIR="$PRIMARY_ROOT" \
      GROK_WORKSPACE_ROOT="$PRIMARY_ROOT" bash -c "cd \"$PRIMARY_ROOT\" && $1"; }
    run "$CLAUDE_PROMPT" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt_id\":\"c1\",\"prompt\":\"claude captain\"}"
    run "$CLAUDE_STOP" "{\"hook_event_name\":\"Stop\",\"prompt_id\":\"c1\",\"last_assistant_message\":\"claude main\"}"
    run "$CODEX_PROMPT" "{\"hook_event_name\":\"UserPromptSubmit\",\"turn_id\":\"x1\",\"prompt\":\"codex captain\"}"
    run "$CODEX_STOP" "{\"hook_event_name\":\"Stop\",\"turn_id\":\"x1\",\"last_assistant_message\":\"codex main\"}"
    run "$GROK_PROMPT" "{\"hookEventName\":\"user_prompt_submit\",\"promptId\":\"g1\",\"prompt\":\"grok captain\",\"hook_event_name\":\"UserPromptSubmit\"}"
    run "$GROK_STOP" "{\"hookEventName\":\"stop\",\"promptId\":\"g1\",\"lastAssistantMessage\":\"grok main\",\"hook_event_name\":\"Stop\"}"
    run "$CURSOR_PROMPT" "{\"hook_event_name\":\"beforeSubmitPrompt\",\"generation_id\":\"u1\",\"prompt\":\"cursor captain\",\"cursor_version\":\"x\"}"
    run "$CURSOR_RESPONSE" "{\"hook_event_name\":\"afterAgentResponse\",\"generation_id\":\"u1\",\"text\":\"cursor main\",\"cursor_version\":\"x\"}"
  ' || fail "a tracked mirror hook failed"
  out=$(entries "$home")
  assert_equals "captain|claude captain
main|claude main
captain|codex captain
main|codex main
captain|grok captain
main|grok main
captain|cursor captain
main|cursor main" "$out" "every tracked registration must write its captain prompt and main reply, in order"
  pass "mirror: the Claude, Codex, Grok, and Cursor registrations each write the captain's prompt and main's reply"
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

test_writers_are_inert_without_the_opt_in() {
  local home crew out
  home=$(make_home no-opt-in 0)
  as_session "$home" '
    printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hello\"}" | "$MIRROR" hook claude
    printf "hello" | "$MIRROR" append captain
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
    printf "%s" "{\"hookEventName\":\"user_prompt_submit\",\"prompt\":\"<system-reminder> Background task completed (exit code: 0).</system-reminder>\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook grok
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
  LONG=$long as_session "$home" '
    for n in 1 2; do printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt_id\":\"p1\",\"prompt\":\"once\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude; done
    printf "%s" "$LONG" | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" append main --id long
  ' || fail "a writer failed"
  [ "$(grep -c '"text":"once"' "$home/state/.host-mirror.jsonl")" -eq 1 ] || fail "an entry whose id is already recorded must not be appended again"
  text=$(jq -r 'select(.id == "long") | .text' "$home/state/.host-mirror.jsonl")
  assert_contains "$text" "[mirror truncated: 1000 characters omitted]" "a long entry must be capped with a truncation note"
  [ "${#text}" -lt 4100 ] || fail "a capped entry kept ${#text} characters"
  pass "mirror: a repeated entry is recorded once, and a long entry keeps its head and tail"
}

test_feed_resumes_reanchors_and_is_bounded() {
  local home out
  home=$(make_home feed)
  as_session "$home" '
    add() { printf "%s" "$2" | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" append "$1"; }
    add captain "first ask"; add main "first answer"
    "$MIRROR" feed s1 new > "$FM_HOME/feed.1"
    add captain "second ask"
    "$MIRROR" feed s1 resume > "$FM_HOME/feed.2"
    "$MIRROR" feed s1 resume > "$FM_HOME/feed.3"
    "$MIRROR" feed s2 resume > "$FM_HOME/feed.4"
  ' || fail "the first session failed"
  assert_equals "[captain] first ask
[main] first answer" "$(cat "$home/feed.1")" "a new conversation must be fed this session's dialog"
  assert_equals "[captain] second ask" "$(cat "$home/feed.2")" "a resumed conversation must be fed only what is new"
  assert_equals "" "$(cat "$home/feed.3")" "a resumed conversation with nothing new must be fed nothing"
  assert_equals "[captain] first ask
[main] first answer
[captain] second ask" "$(cat "$home/feed.4")" "a conversation the cursor does not belong to must re-anchor"

  as_session "$home" '
    printf "%s" "a later session" | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" append captain
    "$MIRROR" feed s3 new > "$FM_HOME/feed.5"
    big=$(awk "BEGIN { for (i = 0; i < 3000; i++) printf \"y\" }")
    for n in 1 2 3 4 5 6 7; do printf "%s" "$n $big" | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" append main; done
    "$MIRROR" feed s4 new > "$FM_HOME/feed.6"
  ' || fail "the second session failed"
  assert_equals "[captain] a later session" "$(cat "$home/feed.5")" "a new main session must never be fed an earlier session's dialog"
  out=$(cat "$home/feed.6")
  assert_contains "$(head -n 1 "$home/feed.6")" "earlier mirrored entries are not shown)" "a bounded feed must say what it left out"
  assert_contains "$out" "[main] 7 yyy" "a bounded feed must keep the newest entries"
  assert_not_contains "$out" "[captain] a later session" "a bounded feed must drop the oldest entries"
  [ "${#out}" -le 16100 ] || fail "the feed was not bounded: ${#out} characters"
  pass "mirror: the feed resumes from its cursor, re-anchors on a new conversation or session, and is bounded"
}

test_verified_writers() {
  local harness
  for harness in claude codex cursor grok opencode; do
    "$MIRROR" verified "$harness" || fail "$harness must have a verified dialog mirror"
  done
  for harness in omp kimi pi unknown; do
    ! "$MIRROR" verified "$harness" || fail "$harness must not claim a verified dialog mirror"
  done
  pass "mirror: exactly the primaries with a proven writer report a verified mirror"
}

test_every_harness_registration_writes_the_mirror
test_codex_hooks_read_the_rollout_transcript
test_writers_are_inert_without_the_opt_in
test_operational_foreign_and_unowned_input_is_dropped
test_entries_are_deduplicated_and_capped
test_feed_resumes_reanchors_and_is_bounded
test_verified_writers
