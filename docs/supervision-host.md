# Supervision host

The supervision host runs the supervision branch's contract beside a primary that is not Pi.
On Pi the branch is a second conversation inside the captain's own process ([pi-supervision-branch.md](pi-supervision-branch.md)); off Pi no such process exists, so the host owns the watcher cycle for the primary and runs the branch as a headless engine session.
It is one architecture with Pi's, not a second one: the same branch prompt, the same row eligibility, the same records, and the same guarded scripts decide what the branch may do.

## Scope today

The host is opt-in per home through `config/supervision-host`; [configuration.md](configuration.md#supervision-host-configsupervision-host) owns the file.
Without the file every home behaves exactly as it does without the host.
Today it runs beside a Claude, Cursor, OpenCode, omp, Grok, or Codex primary, away on all six and attended on Claude, Cursor, and Codex, the primaries with a verified dialog mirror ("Postures" and "The dialog mirror" below):

- Attended (no away-posture record `state/.afk-contract`), the engine takes the wakes the Pi branch would take and never wakes main for a routine outcome; every other close reaches main exactly as the plain watcher arm delivers it.
  On OpenCode, omp, and Grok every attended close reaches main, as without the host.
- Away (the record exists), the host hands each close to the engine, and main stays parked unless the host hands the wake back.
- `/afk` launches no away daemon on an opted-in home of those harnesses, because the host is the away session there.
- `/quiet` needs nothing where the attended host runs, because the attended posture already is quiet mode; `bin/fm-afk-launch.sh quiet-check` decides, and a quiet entry refuses there.
  While the broken-session latch holds, until a probe succeeds, `quiet-check` says instead that the session is paused, that routine wakes reach main until it recovers, and when it retries; no daemon starts.
  While the flag `state/.afk` of a quiet daemon from an earlier entry exists, the host stands aside exactly as the plain arm does.
- Pi keeps its in-process branch whether or not the file exists, and no Pi engine is built.
- Kimi has no primary supervision protocol, so it has no arm owner to run the host.

The daemon's retirement and turning the host on by default are later steps of the same design; until they land, their current behavior stays as described in their own owners.

## Components and their owners

- The loop: `bin/fm-supervision-host.sh`, whose header owns the per-close order, the park boundary, ownership checks, predecessor cleanup, state files, and tunables.
- The arm owners: each primary's existing arm owner runs the host in place of its watcher command for an opted-in home and delivers a handed-back wake through the wake path that harness already trusts; the host's header owns the output contract they read.

  | Primary | Arm owner | A handed-back wake reaches main as |
  |---|---|---|
  | Claude | the Stop auto-arm, `bin/fm-claude-stop-autoarm.sh`, inside its single-flight generation | the hook's exit-2 rewake (`Stop hook feedback`) |
  | Cursor | the `stop` hook park, `bin/fm-turnend-guard-cursor.sh` | the park's `watcher` follow-up |
  | OpenCode | the TUI plugin, `.opencode/plugins/fm-primary-watch-arm.js`, which restarts its own successor after each close | a `watcher` prompt through `promptAsync` |
  | omp | the watch extension, `.omp/extensions/fm-primary-omp-watch.ts`, which restarts its own successor after each close | the extension's `watcher` follow-up |
  | Grok | the model's tracked background call, rendered as `bin/fm-supervision-host.sh park` at session start | the background task's completion notification |
  | Codex | the foreground checkpoint, `bin/fm-watch-checkpoint.sh`, in the watcher's place | the checkpoint's own output |

  Hook, plugin, extension, and checkpoint owners pass their harness as the primary pin; Grok's model-owned call relies on primary detection.
  The host pins dispatched work to the primary's crew harness rather than the engine's.
  Grok's arm command is fixed when the session-start block renders, so adding or removing the file on a Grok home takes effect at the next session start; the other owners read the file at every arm.
- The engine: `bin/fm-supervision-engine-lib.sh` owns the opt-in parse, the verified-engine list, and one bounded engine turn, including the reap of engine tool processes that outlive it.
- Row eligibility: `bin/fm-branch-dispatch.mjs` is the command entry to `.pi/extensions/lib/fm-branch-dispatch.ts`, so the host and the Pi extension compute branch-claimable rows and their task scope from one owner; it also renders the wake message with the same away-posture tail.
- The grant and the drain: `bin/fm-wake-grant.sh` publishes the branch's rows bound to the host's own process, and [watcher-continuity.md](watcher-continuity.md#per-actor-acknowledgement) owns the per-actor drain and acknowledgement the engine runs.
- The prompt: `bin/fm-branch-prompt.sh` emits the same byte-stable prompt the Pi branch runs; each wake names its host's report surface.
- The report surface: `bin/fm-branch-report.sh` is the command twin of the Pi branch's `fm_branch_report` tool, with the same task scoping, and it appends to the outcome store (`bin/fm-branch-outcome.sh`) plus a per-turn receipt the host requires; a row recorded after the captain returned is also queued for main as a durable check wake.
- Leases and authority: `bin/fm-lease-lib.sh` owns the per-task leases, the main-owned role partition, and the away relocation; the host's engine runs with `FM_SUPERVISION_ACTOR=branch`, the session-lock holder as `FM_LEASE_HOLDER_PID`, and the primary's harness pin, so every guarded script treats it exactly as it treats the Pi branch.
- The dialog mirror: `bin/fm-host-mirror.sh` owns the mirror file, its writers' rules, its verified-writer list, and the feed ("The dialog mirror" below).
- The captain-outcome drain: `bin/fm-wake-drain.sh` presents unprocessed captain outcomes in its `BRANCH OUTCOMES` section, and `bin/fm-branch-outcome.sh mark-processed` is main's acknowledgement ("Captain outcomes" below).
- The main side: [supervision-protocols/supervision-host.md](supervision-protocols/supervision-host.md) is what main reads at session start on an opted-in home, rendered for its harness.

## Postures

The posture is the away-posture record, read at every close and again when a turn starts, exactly as the Pi branch reads it.

Attended, the host asks the Pi branch's offer rule (`branchOfferForWake` in `.pi/extensions/lib/fm-branch-dispatch.ts`, through `bin/fm-branch-dispatch.mjs offer`) whether the branch may take the close, so a close reaches main off Pi exactly when it would on Pi: a check trigger, a decision-owned signal or stale trigger, and a scan that is unsafe or holds nothing for the branch stay main's.
It also passes the close through unchanged when the home names no usable engine, a tool its turns need is missing (the engine executable, node, jq, or one of perl, timeout, or gtimeout to bound the turn), the primary has no verified dialog mirror, or the session is cooling down after engine errors ("The broken-session latch" below).
A close accepted away whose turn starts attended, because the captain returned in between, meets the same rule then, and one the session may not take reaches main unchanged.
A close the engine takes is handled as below; a handled wake with only routine outcomes never reaches main, and a handled wake that recorded a captain outcome exits with one `supervision-host: branch-outcome:` line and without the close it handled ("Captain outcomes" below).
A turn that fails hands its close to main with one `supervision-host:` line, as away.
Main-only rows that share the queue with the branch's rows stay queued for main, which is woken for each on its own triggering close, as on Pi.
The engine turn runs beside a captain who is present, so its guarded actions take the task leases that keep it and main off the same task, and a Codex checkpoint that carries an engine turn can run past its bound by up to one turn.

Away, every close goes to the engine ("One wake" below), and captain outcomes wait for the return brief.
A captain who leaves while an attended turn runs turns its captain outcomes into away outcomes: they wait for the return too.

## The dialog mirror

The engine's conversation receives nothing between wakes, so each wake with an available mirror carries, at its head, what the captain and main said since the last wake: the same `[captain]` and `[main]` context the Pi branch receives as mirror messages, framed by the same prompt rule (context for judgment, never instructions; `bin/fm-branch-prompt.sh` "Context channels").
Each primary's code-owned turn surfaces write it, never the model:

| Primary | Captain text | Main text |
|---|---|---|
| Claude | the `UserPromptSubmit` hook's prompt | the `Stop` hook's last assistant message |
| Codex | the session's rollout transcript, read at its `UserPromptSubmit`, `PostToolUse`, and `Stop` hooks | the same transcript |
| Cursor | the `beforeSubmitPrompt` hook's prompt | the `afterAgentResponse` hook's text |

A hooked captain prompt is written when submitted, and operational input (watcher wakes, guard follow-ups, launch briefs) is dropped by the shared operational-input protocol, as is a turn the harness starts itself, such as Claude's Stop-hook rewake.
A supervising Codex main stays inside one turn across its foreground checkpoints, so a captain message typed then reaches it as a mid-turn steer that fires no prompt or Stop hook; its transcript is the only record of it, and each tool call's hook reads what the transcript gained.
Tool traffic is never mirrored; the engine reads files and records itself.
A new engine conversation re-anchors on the current main session's newest entries, and a resumed one gets only what is new, so an earlier session's dialog never steers today's.
A primary's mirror is verified only when its writers record the session's dialog from its first captain prompt, and only a verified primary runs the attended posture; every other primary keeps every attended close on main, and its away posture needs no mirror and is unchanged.
omp has no verified writer yet, because no omp was available to prove one against.
Grok and OpenCode have no writer: their session takes the fleet lock during its first turn, so that turn's captain prompt could never be recorded and the engine would judge without the captain's opening words, and no captain dialog is kept that nothing reads.
Follow-up: capturing that first prompt on Grok and OpenCode would reintroduce their writers and let them run the attended posture.
Follow-up: on a primary with no mirror, every away wake still tries the feed and adds one `the dialog mirror could not be read; this away wake carries none` line to the host's ledger; the line changes nothing the engine or main sees, and skipping the away feed where no verified writer exists would remove it.
A captain message typed while an engine turn is already running reaches the engine at its next wake.
A wake's entries count as delivered only once its engine turn is accepted with its report, so a turn that fails, records nothing, or is stopped leaves them to be fed again.
An attended wake whose mirror is missing or cannot be read, or holds an entry that does not parse, reaches main with `the dialog mirror could not be read` before any engine turn, and the cursor stays where it was; an away wake runs without the mirror.

## Captain outcomes

A captain-verdict outcome the attended engine records wakes main once, through the owner's ordinary wake path, with one `supervision-host: branch-outcome:` line naming its store rows.
Main drains, and `bin/fm-wake-drain.sh` presents every unprocessed captain outcome in its `BRANCH OUTCOMES` section, oldest first and bounded, with the exact `bin/fm-branch-outcome.sh mark-processed --through <seq>` acknowledgement; that presentation is what the Pi branch's visible entry is, so it advances the store's read cursor through the rows it presents, and a row its byte cap leaves out stays unread and follows on the next drain.
Every later drain, including the session-start digest, presents them again until main acknowledges them, so an ignored outcome costs no extra turns and is never lost.
One limit: if the captain goes away and returns while an attended engine turn is running, and the host is terminated before that turn's `branch-outcome` wake is delivered, no immediate wake reaches main; the captain row is still durable, and the next drain's `BRANCH OUTCOMES` section presents it until it is acknowledged with `mark-processed`.
The section runs only for main on an opted-in home whose primary is not Pi, and never while the away record exists; after the return it presents the away window's captain outcomes, which the return brief also listed, as the Pi branch does after a return.
An unprocessed captain outcome is never adopted as processed, so a home that opts in mid-session cannot lose its first one; outcomes recorded before this section existed are presented once more, the safe direction.
Routine outcomes never open a main turn: the next drain lists each once, above the captain outcomes and with nothing to acknowledge, the way the Pi branch's routine notes reach main's transcript without a turn, and silent fleet reviews never appear.
Anything main must act on while attended to move the work forward, such as a local-only branch to land or a pull request to merge, is a captain outcome even when the captain asked not to hear about that work or an earlier outcome already told main (`bin/fm-branch-prompt.sh` "Verdict: routine or captain"), because a routine outcome opens no main turn and would leave it waiting for main's next wake.

## The broken-session latch

The host copies the Pi branch's broken-session policy ([pi-supervision-branch.md](pi-supervision-branch.md#components-and-their-owners)), with an engine error in place of a provider error: a turn that exited nonzero, hit its bound, or ended without a complete successful result.
Two consecutive engine errors latch the session: every wake reaches main for a five-minute cooldown, the attended close unchanged and the away close with a `supervision-host:` line, after which one wake probes the engine, and each probe that ends in another engine error doubles the cooldown up to one hour.
A turn that records a report without an engine error clears the latch; a turn that records no report neither counts toward it nor clears it.
The first trip adds one `supervision-host:` line to the failing turn's handback, and an attended recovery exits with one line saying so, while an away recovery is only logged.
The latch belongs to one main session, engine, and model, so a new main session or another engine or model starts clean.

## One wake

On each actionable close the engine takes, the host first starts and verifies the successor watcher cycle and confirms the handling handoff, so the fleet stays supervised while the engine works.
It then computes the branch-claimable rows in the turn's posture, publishes the grant, and runs one bounded engine turn with the branch prompt and the wake message carrying the dialog mirror when available and, away, the record's read-back.
The engine drains, handles, reports through `bin/fm-branch-report.sh`, and acknowledges, exactly as the Pi branch does.
The host counts the wake handled only when the turn exited cleanly, recorded at least one report, and left none of its granted rows in the wake queue; it releases the branch's leases and grant either way and parks on the successor only for a handled wake.
Away, a handled wake never reaches main, whether its outcome was routine or captain: captain outcomes wait in the outcome store, and the return brief (`bin/fm-afk-return.sh`) presents them.
The one exception is a captain who returns while an away turn is still running: the return brief was rendered before that turn's outcomes existed, so the host hands the close to main with those outcomes for main to relay, whether or not the turn handled its wake.
That handoff is only the prompt delivery: each outcome recorded after the return is already a queued `check` wake, because the return owner archives the record before it reads the store and the report surface queues any row it records once the record is gone.
So the outcome reaches main's drain even when the handoff is lost, as when a Cursor park superseded by the return turn's own end stops its host as the engine turn finishes.

## Failure direction

Every path that cannot finish a wake the engine took hands that wake to main, with one `supervision-host: <why>` line after the close; the host adds no delivery path of its own, so its fallback is always today's reason line through the owner's own wake path.
Before handing it back, the host stops its successor cycle, so the owner's next arm starts from the same state as without the host and the wake stays durable in the queue.
That covers an unverified successor, a refused handoff, an unreadable queue, rows main already claimed, a missing engine or node, a turn that timed out or failed, a turn that recorded no report, and a turn that reported but left any of its granted rows unacknowledged.
The last names those rows, which stay durable in the queue for main's drain.
A turn that fails also starts the next wake on a fresh engine conversation.
When the captain returned during a failed turn that recorded outcomes, the handback carries those outcomes too, for main to relay.
When the host loses session-lock ownership or its auto-arm generation, it stands down silently and leaves continuity to whoever owns it now.
A host that starts without that ownership stands down before activation, so it never stops the owner's host or watcher or releases its leases.
A host that dies without a close is retried by its owner (Grok's model and Codex's checkpoint see it as a failed cycle and start the next one), and the next host stops, by recorded identity, whatever its predecessor left running, including the engine descendants a killed turn recorded, and removes that turn's files before it arms.

## The park boundary

Claude drops the exit 2 of a Stop hook it terminated at the hook timeout ([verification](verification/supervision.md#claude-drops-the-exit-2-of-a-hook-it-timed-out-2026-09-23)), and Cursor's `stop` hook carries the same tracked 28,800-second registration.
A plain watcher park rarely lasts that long, because heartbeat closes wake main, but a host absorbs its own wakes, so it ends its park itself before that registration.
`FM_SUPERVISION_HOST_PARK_SECONDS` sets that boundary (default 27,000), and a value that is not a positive integer below 28,800 is treated as the default.
The OpenCode, omp, and Grok owners have no hook timeout and keep the same default, so their parks end on the same cadence.
At the boundary it stops the home's watcher and exits with one `supervision-host: cycle boundary` line; main drains and acknowledges, and the owner starts the next park (at the next turn end on Claude and Cursor, at once for OpenCode and omp, and at the model's re-arm on Grok).
The host checks the boundary on every loop pass, so closes that are already waiting cannot carry it past the boundary.
It also starts no engine turn that could still be running at the boundary (the turn bound plus the engine grace), judged when the close arrives and again just before the turn starts: that close reaches main ahead of the boundary line instead, and its wake stays durable in the queue.
One short main turn per boundary is the cost of never losing the park silently.

Codex has no asynchronous wake, so its checkpoint's own bound is the park: the checkpoint passes it as the boundary and reports the boundary as its ordinary quiet line (`checkpoint: no actionable wake within <n>s`).
Attended the bound stays `FM_CODEX_WATCH_CHECKPOINT` (default 180 seconds); while the away record exists it is raised to `FM_CODEX_WATCH_CHECKPOINT_AWAY` (default 3,600) if longer, then capped at 27,000 seconds so a parked main is not woken every few minutes.
Because that bound is not a harness timeout, the checkpoint also sets `FM_SUPERVISION_HOST_PARK_LIMIT`, which lets an engine turn that starts before the boundary finish after it; a captain message typed during the park waits for the checkpoint to return, at most the bound plus one engine turn, unless the captain interrupts it.

## Engine conversations

The engine keeps one conversation across wakes so the byte-stable prompt stays cached, keyed to the current main session: every main session start opens a new one, and so does every `FM_SUPERVISION_HOST_ROTATE_TURNS` turns, because each wake adds history and the per-wake cost grows with it.
Nothing captain-facing rides on that conversation, because the outcome store carries every result.
The dialog mirror at the head of a wake is captain context when available; away, the record's read-back at the tail of every wake is the mandate it acts on.
`state/.supervision-host.log` records where every close went, and each engine turn's line carries its result, the engine's reported usage, the turn's cost, and the conversation's running cost, which is where engine cost is read today.

## Engines

A verified engine is a headless mode of a harness whose isolation, actor propagation, promptless permissions, bounding, and caching were measured.
Today the only verified engine is Claude's print mode, measured on Claude Code 2.1.278 and 2.1.281:

- `--safe-mode` loads none of the home's hooks, `CLAUDE.md`, skills, plugins, or MCP servers, so the engine can never fire the home's own Stop or SessionStart hooks; `--bare` is unusable because it never reads claude.ai OAuth.
- `--permission-mode dontAsk` with the `Bash` and `Read` allowlist never prompts: a denied call reaches the model as a tool error and never wedges the turn; `--safe-mode` does not override the user's default mode, so the mode is always passed.
- Claude path-checks direct file reads against its working directories, so a home or state directory outside the code root is passed with `--add-dir`.
- The conversation starts with `--session-id` and continues with `--resume`; the prompt is the first argument and stdin is `/dev/null`, because an open stdin costs a three-second wait.
- `--output-format json` carries the error flag, turn count, usage, and the tool's own cost estimate; on a resumed conversation that cost is the conversation's running total while the usage and turn count are the turn's own, so the engine lib derives each turn's cost from the total the host recorded after the previous turn.
- The host counts a turn successful only when that result is complete: `type` is `result`, `subtype` is `success`, `is_error` is false, and `total_cost_usd`, `num_turns`, and the four `usage` token counts (input, cache read, cache creation, output) are finite numbers; any other result fails the turn and hands its wake to main.
- The engine runs from the tracked code root, so its session files land in Claude's own project store for that directory and appear in that directory's resume list.
- Tool commands run in process groups of their own, which a bound's group signal cannot reach, so the engine lib records the engine's descendants once a second and reaps them by recorded identity after every turn; the reap is best-effort for what it observed, not a bound, so a process that a tool detaches into a process group of its own and that loses its ancestry to the engine between two snapshots is never recorded and survives the turn, the same residual `bin/fm-timeout-lib.sh` names.
- From inside the engine's shell the primary is not in the harness ancestry, so the engine can never act as the session-lock owner.

The default model is `sonnet`, which handled every measured wake correctly at a fraction of a larger model's cost; `config/supervision-host` can name another.
The Claude engine runs beside any of the six primaries, but only a Claude primary selects it by default: a Cursor, OpenCode, omp, Grok, or Codex home names it (`claude`, optionally with a model) in `config/supervision-host`, and `/afk` there says so when the file selects no engine.

## Verification

`tests/fm-supervision-host.test.sh` drives the real host, auto-arm, grant, drain, report, and lease scripts against a stub engine.
Each arm owner's own suite covers its host mode against a stub host: `tests/fm-claude-stop-autoarm.test.sh`, `tests/fm-cursor-primary.test.sh`, `tests/fm-pi-watch-extension.test.sh` (the OpenCode plugin), `tests/fm-omp-harness.test.sh`, `tests/fm-watch-checkpoint.test.sh`, and `tests/fm-supervision-instructions.test.sh` (the rendered protocol, including Grok's arm command).
`tests/fm-supervision-host-live-e2e.test.sh` runs a real engine turn and is opt-in because it spends tokens.
[verification/supervision.md](verification/supervision.md#supervision-host) records the dated live results.
