# Demo prompts

Canned prompts to try against the `prior-auth-assistant` agent. Expected
tool-call and response behavior noted for each.

## Happy path — escalation triggers

**Prompt**
```
What's the status of PA-2026-88421?
```

**Expected**
- Tool call: `check_prior_auth_status({"priorAuthId": "PA-2026-88421"})`
- Workflow: Pending, 5 business days → escalate → mock ticket + optional Teams post
- Agent response: mentions Ozempic 1mg, member M-99231, 5 days, escalation ticket `INC00XXXXXX`, next-step SLA 24 hours

## Happy path — within SLA

**Prompt**
```
Any update on PA-2026-88424?
```

**Expected**
- Pending, 1 business day
- No escalation
- Agent response: Trulicity 1.5mg for member M-58024, pending, within SLA, no escalation needed

## Approved

**Prompt**
```
Check PA-2026-88422 for me.
```

**Expected**
- Approved
- Agent response: Humira for member M-40182 is approved

## Denied — surface reason

**Prompt**
```
Why was PA-2026-88423 denied?
```

**Expected**
- Denied
- Agent response: Xolair for member M-72910 denied because "Step therapy not completed — trial of inhaled corticosteroid required per plan formulary."

## Missing PA ID — agent should ask

**Prompt**
```
Any update on the prior auth for one of my members?
```

**Expected**
- No tool call yet
- Agent asks for the PA ID

## Not-found path

**Prompt**
```
Status of PA-2026-99999?
```

**Expected**
- Tool returns 404
- Agent response: cannot find that PA — asks user to double-check the ID

## Multi-turn — chained lookup

**Prompt 1**
```
Check PA-2026-88425.
```

**Prompt 2 (same session)**
```
And the one before that in the queue — PA-2026-88424?
```

**Expected**
- Two separate tool calls
- Agent narrates both results, differentiating that 88425 was escalated (7 days) and 88424 was not (1 day)
