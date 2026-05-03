---
name: distill
description: Scan a project's recent activity (PROGRESS.md, completed task results, current WORKING_MEMORY) and produce a proposal document of durable lessons, new skills, or PROTOCOL.md refinements that the admin should review. Distillation outputs PROPOSALS, never direct mutations to skills or policy. Use when admin requests a manual distill, or when a future scheduled distill cron job fires.
---

# distill

Self-evolution for the super-agent — but **proposal, not application**. The distill skill reads what happened recently and suggests what's worth crystallizing into durable form. Admin gates the actual write to skills, WORKING_MEMORY, or PROTOCOL.md.

## When to invoke

- Admin asks: "distill the research project" / "what should we promote to working memory?" / "any patterns worth turning into a skill?"
- **Weekly cron** — fires Friday 4:23pm local (per PROTOCOL.md §5). Iterates every `~/projects/<name>/` where `<name>` does not start with `_`; runs distill on each project that has ≥5 PROGRESS entries within the past 7 days, otherwise skips (per the "too new" anti-pattern below).
- **Post-task flag** — when a subagent writes `flag_for_distill: true` in `tasks/<id>/result.md` frontmatter (see workspace-memory SKILL §"Bootstrap protocol" step 10), the orchestrator dispatches an immediate distill run on that task's project — no waiting for the weekly cron.

## Inputs

- A target project name (or `_admin` for cross-project distill).
- Optional time window (default: past 7 days).

## What distill reads

1. The project's `PROGRESS.md` (entries within the time window).
2. The project's `WORKING_MEMORY.md` (so proposals don't duplicate existing entries).
3. Completed `tasks/<id>/result.md` files within the window.
4. Existing skills in `skills/` (so a "propose new skill" suggestion doesn't reinvent one).
5. (For `_admin/` distill only) `_admin/log.jsonl` for patterns in admin auth decisions.

## What distill produces

A single markdown file at `~/projects/_admin/distill-proposals/<YYYY-MM-DD>-<project>.md` with sections:

```markdown
---
distilled_at: <ISO>
project: <project name>
window: <ISO range>
status: pending_review
---

# Distill proposal — <project>

## Summary

<2-3 sentences on what happened in the window>

## Proposed promotions to WORKING_MEMORY.md

<bulleted list. each entry: the proposed line + which PROGRESS entry/task result it came from + why it's durable>

## Proposed new skills

<each: skill name, one-paragraph description, the 2-3 task patterns that motivated it. Empty if no recurring patterns.>

## Proposed updates to existing skills

<each: skill name, suggested change, the experience that motivated it. Empty if nothing surfaced.>

## Proposed PROTOCOL.md refinements

<rare; only when a real protocol-level gap was hit. Most distill runs produce nothing here.>

## Things deliberately NOT promoted

<entries the LLM considered but rejected — gives admin visibility into the judgment>

## Admin actions

- [ ] Approve all proposed WORKING_MEMORY promotions
- [ ] Approve specific proposals (mark which)
- [ ] Reject proposal entirely
- [ ] Request rework with feedback
```

## Decision rubric (LLM-judged)

For each candidate "thing to promote":

- **Will this still be useful in 6 months?** Yes → promote candidate. No → leave in PROGRESS, will eventually archive.
- **Is this already in WORKING_MEMORY in some form?** Yes → don't propose a duplicate. Possibly propose a refinement.
- **Did this lesson recur (3+ instances)?** If so, strong candidate. One-off observations rarely make it.
- **Is this project-specific or cross-cutting?** Project-specific → project's WORKING_MEMORY. Cross-cutting → propose for the agent's global memory or a new skill.

## Application flow (after admin reviews)

1. Admin reads `_admin/distill-proposals/<file>`, marks which proposals to apply.
2. Admin replies "apply these" (with the checkbox list) or quotes specific items.
3. The orchestrator (or a follow-up subagent) applies the approved changes:
   - WORKING_MEMORY.md edits (atomic write, see workspace-memory SKILL).
   - New skill creation (mkdir + SKILL.md write).
   - Skill SKILL.md edits.
   - PROTOCOL.md edits.
4. Each application is a separate `kind: admin_action` log entry.
5. The proposal file is moved to `~/projects/_admin/distill-proposals/applied/<file>` (or `rejected/` if denied).

## Anti-patterns

- **Don't apply silently.** Even an obvious-seeming promotion needs admin sign-off. The distill skill produces proposals; it does not mutate state.
- **Don't propose if the project is too new.** A project with <5 PROGRESS entries usually has nothing to distill yet — the skill should output a one-line "too early to distill" note rather than fabricating proposals.
- **Don't propose adding to PROTOCOL.md casually.** That file is the policy spine; refinements there are rare and high-stakes.
- **Don't include the same proposal twice.** Cross-check against WORKING_MEMORY and existing skills before writing.

## Reference

- PROTOCOL.md §7 (Self-evolution) describes the high-level intent.
- workspace-memory/SKILL.md §"Grooming" describes the related daily-groom and weekly-distill jobs that run grooming tasks; this skill specifically owns the "distill" half.
