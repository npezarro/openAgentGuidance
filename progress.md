# progress.md

## 2026-08-19 — created and rebuilt

- `3993a7e` init: repo skeleton (README, LICENSE, CI scan workflow)
- `d554527` lessons: first distilled batch — **superseded**, this shape was wrong
- `b120179` replace lesson essays with the actual working harness: agent.md, ESSENTIAL.md, 14 hooks, 8 subagent definitions, secret-scan.sh, install.sh, templates, MANIFEST
- `e5306e2` hooks: fix user-facing strings mangled by a blanket rename; verified the gate end to end in a throwaway repo
- `dd3825a` guidance: publish the remaining 14 rewritten files; add `.secret-scan-allow`
- `52007b2` guidance: sync four lessons on verification and destructive edits
- `c1cd697` ESSENTIAL: shadowed tools, and validating a deliverable's shape (hand-written)

### Why the rebuild

The first version distilled the source into five abstract essays. Correctly screened, isolated distiller, fail-closed gate, daily cron, and useless: nobody can use a principle with every operational detail removed. Rebuilt as the harness itself. The lesson became `ESSENTIAL.md` rule 9.
