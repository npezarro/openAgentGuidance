<!-- Load when: /goal for headless runners: mission-file pattern, condition rules, BLOCKED escape hatch -->
# /goal Conditions for Headless Runners

Claude Code >= 2.1.139 supports `/goal <condition>`. The session keeps re-prompting itself, turn after turn, until a small evaluator model judges the condition satisfied. Then it stops. In headless mode the goal string is the prompt: `claude -p "/goal ..."`. The point is that a run no longer ends because "the session decided it was done". It ends because "the session proved it was done". This enforces "verify before claiming completion" and "paste evidence, then claim" at the harness level.

## Where to use it

- **Cron and scheduled runners** (daily dev runners, periodic review or learnings passes, fix-checkers): wrap them in a shared helper, for example `runner_claude_goal` in your runner library.
- **Templated task jobs** dispatched from a bot or queue: pass a generic goal condition. Let a per-template `goal` field override it.
- **Conversational or question-answering jobs:** leave these goal-less on purpose. A question should not loop on a completion condition.

## The mission-file pattern

The goal condition is capped at 4000 characters, so a large runner prompt cannot be inlined. Write the full prompt to a mission file, then use:

```
/goal Read and execute the mission briefing at <path>. This goal is achieved when
the conversation demonstrates EITHER (a) <condition>; OR (b) a final message
beginning 'BLOCKED:' stating concretely what was attempted and why the mission
cannot be completed.
```

## Rules for writing conditions

1. **The transcript must be able to demonstrate it.** The evaluator only reads the conversation. It never runs commands. "All tests pass" is a bad condition. "The full test command output is pasted, showing it passes" is a good one.
2. **Always include the `BLOCKED:` escape hatch.** Without it, an unmeetable condition loops until the timeout kills the run, and the partial work gets reported as a plain failure.
3. **Name the legitimate no-work outcome.** Some runners can correctly do nothing (no delta since the last run, PR cap reached). Put that outcome in the condition, or quiet runs will loop hunting for work.
4. **Don't send `/goal` on `--resume`.** An active goal is restored with the session. Sending `/goal` again replaces it and orphans the original condition. Guard every consumer against this.
5. **Version-guard and fall back.** If the CLI is older than 2.1.139, or the composed condition is over the cap, fall back to a plain (goal-less) run. A goal must never be the reason a cron produces nothing.

## Traps

1. **Always close stdin in goal mode.** Bash herestrings and heredocs larger than the ~64KB pipe capacity are backed by seekable temp files, not pipes. Your runner may have already drained stdin into the mission file. Even so, `claude -p` re-reads fd0 from position 0 and appends it to the positional prompt. The whole mission then leaks into the goal condition and blows the 4000-char cap. Small prompts travel over pipes and pass, so smoke tests miss this: it only fires above the size threshold. Run every goal invocation with `< /dev/null`.

2. **A rejected goal looks like a success.** When the condition is too long, the CLI still returns a normal-looking result: `subtype: success`, `is_error: false`, exit 0, `num_turns: 0`, cost $0, with the error text as the result. A runner that checks only the exit code logs this as DONE. If that result gets posted to a shared journal or log, the error text can spread into other sessions' context. Detect `"Goal condition is limited"` in the result and rerun without a goal. Treat any goal run with `num_turns: 0` as suspect.

3. **A status update can be accepted as the final message.** A goal run can end with `stop_reason: end_turn`, `subtype: success`, exit 0, and a last message like "Waiting for the subagent to finish before finalizing the run." That is in-progress narration. It is not a structured completion report and not a `BLOCKED:` message. If the caller trusts the exit code, it logs DONE, advances its watermarks or delta gates, and silently drops whatever the in-flight subagent was doing. Nothing is left to retry. **Mitigation:** don't trust the exit code alone. After the run, have the caller check the result for the same markers the condition requires (the structured summary block, or a `BLOCKED:` prefix). If neither is there, treat the run as a failure. This is a caller-side safety check. It does not fix the evaluator, and the evaluator's root cause was never confirmed.

4. **Boilerplate that names your fields can shadow the real values.** Suppose you regex-extract structured fields (`REPO:`, `PR:`, `FILES_CHANGED:` and so on) from the transcript with a first-match, head-anchored pattern (`head -c N | grep -oP ... | head -1`). Any injected preamble that lists those field names will match first: a goal-condition preamble, a template echo, a system reminder. The real summary usually comes last, often past the head window. The result:
   - Free-text patterns capture junk, such as a trailing comma.
   - Digit-only patterns find nothing and silently default to 0.
   - Downstream gates keyed on those values (for example "run the post-run verify only if PR > 0") switch off without any error.

   When the real value is documented to be the final output of the turn, anchor to the **last** match and the **tail** of the text (`tail -c N`, `tail -1`). Replay the fixed parser against real logs before trusting it.

## Operational notes

- **Cost:** the evaluator is a small model and costs little. Goal runs do take more turns than single-pass runs, so keep goal-wrapped crons behind your usage or budget gate.
- **Silence:** with the default text output, a headless goal run prints nothing until the condition is met. Use `--output-format stream-json --verbose`, or the run will look hung.
- **Timeouts still apply.** The goal loops inside your existing `timeout` wrapper, so a looping goal cannot outlive the runner's time budget.
- **Stop hooks:** `/goal` registers a session-scoped, prompt-based Stop hook. The harness manages it. Leave it out of any custom Stop-hook classification or safety tiers you maintain.
- **Hooks must be on,** and the workspace trust dialog must be accepted. `disableAllHooks` disables `/goal` as well.
- **A runner's lock file only serializes the runner against itself.** It does not block a copy of the same mission file that someone runs by hand. Before running a lock-guarded runner's mission manually, check whether the lock belongs to a live process.
  - **First, check ownership:** if the lock's PID is an ancestor of your own shell, you *are* the runner's dispatched child. Proceed, and never report `BLOCKED:` for this.
  - Make this explicit for the child: add an ownership header to its prompt, or write an owner sidecar file next to the lock. Otherwise runs can kill themselves by detecting their own parent's lock.
