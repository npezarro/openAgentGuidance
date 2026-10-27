<!-- Load when: /goal for headless runners: mission-file pattern, condition rules, BLOCKED escape hatch -->
# /goal Conditions for Headless Runners

Claude Code >= 2.1.139 supports `/goal <condition>`. The session re-prompts itself turn after turn until a small evaluator model judges the condition satisfied, then stops. In headless mode the goal string IS the prompt (`claude -p "/goal ..."`). This turns "the session decided it was done" into "the session proved it was done". It enforces "verify before claiming completion" and "paste the evidence, then make the claim" at the harness level.

## Where to use it

- **Scheduled or cron runners** (daily dev runners, review passes, fix checkers): wrap them in a shared helper that composes the goal, applies the guards below, and falls back to a plain run.
- **Templated task jobs** dispatched from a bot or queue: give them a generic completion condition, and let each template override it with its own `goal` field.
- **Conversational request jobs should not have a goal.** A question must not loop on a completion condition.

## The mission-file pattern

The goal condition is capped at 4000 characters, so you cannot inline a large runner prompt. Write the full prompt to a mission file, then:

```
/goal Read and execute the mission briefing at <path>. This goal is achieved when
the conversation demonstrates EITHER (a) <condition>; OR (b) a final message
beginning 'BLOCKED:' stating concretely what was attempted and why the mission
cannot be completed.
```

## Rules for writing conditions

1. **Only use conditions the transcript can demonstrate.** The evaluator reads the conversation. It never runs commands itself. "All tests pass" is a bad condition; "the full test command output is pasted showing it passes" is a good one.
2. **Always include the `BLOCKED:` escape hatch.** Without it, an unmeetable condition loops until the timeout kills the run, and the partial work gets reported as a plain failure.
3. **Cover the legitimate no-work path.** If a runner can correctly do nothing (no new input, PR cap reached), name that outcome in the condition. Otherwise quiet runs will loop hunting for work.
4. **Skip goals on `--resume`.** An active goal is restored along with the session. Sending `/goal` again replaces it and orphans the original condition. Every consumer must check for this.
5. **Check the CLI version and fall back.** Run without a goal when the CLI is older than 2.1.139 or the composed condition is over the cap. A goal must never be the reason a cron produces nothing.

## Three traps

1. **Always close stdin in goal mode.** Bash herestrings and heredocs larger than the pipe capacity (about 64KB) are backed by seekable temp files, not pipes. The runner may already have copied stdin into the mission file, but `claude -p` still re-reads fd0 from position 0 and APPENDS it to the positional prompt. The whole mission then leaks into the goal condition and goes over the 4000-char cap. Small prompts go through pipes and work fine, which is why smoke tests miss this: it only happens above the size threshold. Run every goal invocation with `< /dev/null`.
2. **A rejected goal looks like a success.** The CLI reports a too-long condition as a normal result: `subtype: success`, `is_error: false`, exit 0, `num_turns: 0`, cost $0, with the error text as the result. Runners that only check the exit code log it as DONE. If the result is posted anywhere shared, the error text spreads further. Check the result for `"Goal condition is limited"` and rerun without a goal, and treat any goal run with `num_turns: 0` as suspect.
3. **A status update can be accepted as the final message.** A run can end with `stop_reason: end_turn`, `subtype: success`, exit 0, many turns in, where the last message is just progress narration ("Waiting for the subagent to finish before finalizing..."). That is not the structured completion report and not a `BLOCKED:` message. If the caller trusts exit 0, it logs DONE, moves its watermarks forward, and whatever the subagent was doing is lost with no error and nothing to retry. **Mitigation:** don't rely on the exit code alone. After the run, have the caller check the result for the same markers the condition requires (the structured block, or a `BLOCKED:` prefix). If neither is there, treat the run as failed. This check happens in the caller and does not fix the evaluator; why the evaluator accepts a status update as final is still unknown.

## Extracting structured output from goal transcripts

If the caller pulls structured fields (for example `REPO:`, `PR:`, `FILES_CHANGED:`) out of the transcript with grep or regex, watch for framework boilerplate that names the same fields. A goal preamble or template echo near the start of the transcript might contain `(SUMMARY:, REPO:, PR:, ...)`. A first-match extraction over the start of the transcript then grabs the trailing comma as the "value", while digit-only fields find no match and quietly default to 0. Downstream gates that depend on those values (for example "run the verify step only when PR > 0") then silently stop running. When the real value is documented as the last output of the turn, use the LAST match and search the end of the text (`tail -c N`, `tail -1`), not the first match from the start (`head`).

## Operational notes

- **Cost:** the evaluator (a small model) costs very little, but goal runs take more turns than single-pass runs. Keep goal-wrapped crons behind your usage or budget gate.
- **Silence:** with default text output, a headless goal run prints nothing until the condition is met. Use `--output-format stream-json --verbose` or the run will look hung.
- **Timeouts still apply.** The goal loops inside your existing `timeout` wrapper, so a looping goal cannot outlive the runner's time budget.
- **Stop hooks:** `/goal` registers a session-scoped, prompt-based Stop hook. The harness manages it, so it does not need the review you would give a custom Stop hook.
- **Hooks must be enabled** and the workspace trust dialog accepted. `disableAllHooks` also disables `/goal`.
- **A runner's lock file only stops it from running twice; it does not stop a manually re-dispatched copy of the same mission.** Before running a lock-guarded runner's mission by hand, check whether the lock belongs to a live child process. **But first check ownership: if the lock PID is an ancestor of your own shell, you ARE the runner's dispatched child, so carry on and never report `BLOCKED:`.** Make this explicit with an ownership header in the child's prompt and an owner sidecar file next to the lock. Without it, children can detect their own parent's lock and kill themselves.
