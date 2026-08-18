# Lesson Index

Each lesson states a rule, the failure it prevents, and how to apply it.

- [In an allow-wins policy engine, enumerate the rules already present before adding narrowly scoped ones](lessons/allow-wins-policy-and-preexisting-rules.md)
- [Commands that resolve their target from shared mutable state are unsafe when anything else can change that state](lessons/bind-the-target-explicitly-under-concurrency.md)
- [A broken credential rotation is a countdown, not a steady state, and the countdown is silent](lessons/credential-rotation-failure-is-a-deadline.md)
- [Read state from an API that queries now, not one that reports a value captured at initialization](lessons/prefer-live-reads-over-cached-state-fields.md)
- [An experiment whose outcome metric fires a handful of times cannot conclude, no matter how long it runs](lessons/rare-outcome-metrics-cannot-evaluate-interventions.md)
