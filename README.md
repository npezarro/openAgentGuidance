# openAgentGuidance

Operating lessons from running coding agents against real infrastructure, day after day, for about a year.

Every lesson here was paid for. Something broke, or quietly did nothing while appearing to work, and the rule below is what stopped it happening twice. They are published because the failure modes turn out to be general: they are properties of agents, schedulers, and monitoring, not of any particular stack.

## What this is

A distilled, public subset of a private agent-guidance repo. The private repo holds the full ruleset, including infrastructure specifics that are nobody else's business. Lessons here are **rewritten, never copied**: each one is restated as a general principle with hostnames, paths, repo names, and people removed. A screening gate blocks publication on any match against a sensitive-identifier list, and fails closed.

That means these are deliberately abstract. You get the principle and the failure it prevents, not a walkthrough of someone else's servers.

## Reading it

Lessons live in [`lessons/`](lessons/), one per file, indexed in [`INDEX.md`](INDEX.md). Each states the rule, why it exists, and how to apply it.

The recurring theme, if you want one before you start: **an automated check that cannot fail loudly is worse than no check at all.** A surprising share of these lessons are variations on that, discovered separately, each time by something silently doing nothing for weeks.

## Using it

Take what is useful. There is no install step and nothing to depend on. If a lesson maps onto your own setup, copy the rule into whatever file your agents actually read.

Issues and discussion are welcome. Pull requests adding lessons are not, since everything here has to come through the screening pass.

## License

MIT. See [LICENSE](LICENSE).
