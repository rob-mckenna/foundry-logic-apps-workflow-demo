# Demo prompts

A 5-minute live demo script with 8 canned prompts, plus bonus prompts and hygiene tips.
Copy any of these directly into `python run_agent.py` or use `python demo_run.py` to cycle
through the core scenarios non-interactively.

---

## Act 1 — The happy path (30 seconds)

### Prompt 1 — one-line query, everything works

```
What's the status of PA-2026-88425?
```

**Expected**: Enbrel 50mg for M-11557, Pending 9 days → **escalated**, ticket `INC00xxxxxx`, next-step SLA 24 hours.

**Talk track**: This is exactly what a care coordinator would ask. Notice the agent extracted the PA ID, called the Logic App workflow, and narrated the SLA breach in plain language — no tool ID, no JSON, just the answer.

---

## Act 2 — The three status paths (60 seconds)

### Prompt 2 — approved case

```
Check PA-2026-88422 for me.
```

**Expected**: Humira for M-40182, **Approved**, 2 days old, no escalation.

### Prompt 3 — denied case with verbatim reason

```
Why was PA-2026-88423 denied?
```

**Expected**: Xolair for M-72910, **Denied**. Denial reason surfaced word-for-word:
_"Step therapy not completed — trial of inhaled corticosteroid required per plan formulary."_

**Talk track**: The workflow returns the denial reason as a string, and the agent's system prompt says to surface it verbatim. In production, this is where we'd add HIPAA de-identification before it enters model context.

### Prompt 4 — pending but within SLA

```
Any update on PA-2026-88424?
```

**Expected**: Trulicity for M-58024, Pending 1 day, **within SLA**, no escalation.

**Talk track**: Same tool call, different branch of the workflow. Business logic — the 3-day SLA threshold — lives in the Logic App, not the model.

---

## Act 3 — The agent's judgment (60 seconds)

### Prompt 5 — force clarification (no PA ID)

```
I'm calling about a member's prior auth. What's the status?
```

**Expected**: Agent recognizes it can't call the tool without a PA ID and **asks for one** rather than fabricating.

**Talk track**: The agent's system prompt explicitly forbids hallucinating PA IDs. Watch it decline to guess — this is how you keep clinical staff safe.

### Prompt 6 — multi-turn context (follow-up to Prompt 5)

```
It's PA-2026-88421.
```

**Expected**: Agent uses the retained context, calls the tool, returns the SLA-breach summary for Ozempic / M-99231.

**Talk track**: State is preserved across the turn — no re-prompting.

---

## Act 4 — Compound reasoning (60 seconds)

### Prompt 7 — two lookups in one utterance

```
Compare the status of PA-2026-88425 and PA-2026-88424 for me.
```

**Expected**: Agent makes **two separate tool calls** in one turn and produces a side-by-side comparison, calling out that 88425 is escalated (9 days) and 88424 is not (1 day).

**Talk track**: The OpenAPI tool description tells the model this is idempotent and safe to call multiple times. That's why it can parallelize the lookups.

### Prompt 8 — downstream reasoning on tool output

```
Which of PA-2026-88421, PA-2026-88422, and PA-2026-88425 is the most urgent, and what should I do next?
```

**Expected**: Three tool calls (or three ordered calls), then the agent ranks by days-outstanding + status and recommends action ("prioritize 88425 — longest overdue at 9 days; 88421 has an open escalation ticket already; 88422 is closed").

**Talk track**: This is the big value-add — the model brings triage reasoning on top of the deterministic workflow data. The Logic App handles orchestration and business rules; the model handles synthesis.

---

## Bonus prompts (Q&A or deeper dives)

### Show tool provenance
```
Where did you get that status information from?
```
Agent explains it called the `check_prior_auth_status` tool. Useful for skeptics who want to see the model isn't inventing data.

### Test resistance to a plausibly-formatted fake PA ID
```
Look up PA-2026-88500.
```
The workflow returns a 404. Currently, Foundry's OpenAPI tool treats non-2xx as a validation error — so the agent surfaces "the lookup failed". Known follow-up: refactor the workflow to always return 200 with an `error` field so the agent can narrate "PA not found in system."

### Design-partner question
```
If I wanted to add formulary lookup as a second tool for you, what would you need?
```
Agent talks about what an OpenAPI spec + Logic App workflow for a formulary lookup would look like — great transition slide to the roadmap.

### Show the SLA rule is enforced by policy, not the model
```
If PA-2026-88425 had been submitted yesterday instead of 9 days ago, would you still escalate it?
```
Agent says no — under 3 business days is within SLA. The agent knows this because the workflow returned `escalated: false` for similar cases. Great way to show the workflow is the source of truth for the business rule.

---

## Live-demo hygiene tips

- **Warm up first**: Run one prompt before the audience is watching. Cold starts on Consumption LA + Foundry can add 3–5 seconds to the first call.
- **Two screens**:
    - Screen 1: `run_agent.py` REPL.
    - Screen 2: Foundry portal, agent run history — pause on a run to show the tool-call arguments and raw response JSON. That view sells the "no hallucination" story better than words.
- **Third screen (optional)**: Azure portal → `la-priorauth-pademo01` → **Runs**. Open a workflow run and show which branches fired (escalation vs. skip). Proves the Logic App is the real orchestrator, not the model.
- **Have "the money slide" ready**: Between Act 3 and Act 4, put up a slide showing the split of responsibilities — agent decides *when* to call, workflow decides *what happens*. Foundry logs the tool-call; Logic Apps logs the orchestration. Two audit trails, both queryable.
- **Skip the tear-down slide**: Just leave the RG deployed for the demo day, then run `az group delete -n rg-foundry-la-pademo -y` after.

