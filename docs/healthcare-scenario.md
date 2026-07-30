# Healthcare scenario framing

## The problem

For **healthcare payers** and **pharmacy benefit managers (PBMs)**, **prior authorization (PA)** is one of the most volume-heavy and time-sensitive workflows in the business. Every day, thousands of PA requests move through a queue where clinical reviewers evaluate whether a prescribed drug or procedure meets coverage criteria (formulary, step therapy, medical necessity).

Two operational realities dominate:

1. **SLA pressure.** Regulators (CMS, state insurance departments), plan contracts, and provider satisfaction all put hard SLA windows on PA turnaround — typically 72 hours for standard PAs, faster for urgent. A PA that silently stalls past its SLA generates rework, member abrasion, and provider complaints.
2. **Fragmented tooling.** Care coordinators, pharmacists, and provider services staff routinely context-switch between the PA platform, ticketing (ServiceNow), Teams, and email to answer the question *"where is PA #X and what happens next?"*.

## What this demo shows

A conversational assistant a care coordinator or pharmacy customer service representative could use:

> **User:** What's the status of PA-2026-88421?
>
> **Agent:** PA-2026-88421 (Ozempic 1mg for member M-99231) has been **Pending for 5 business days** — that's past the 3-day internal SLA. I opened escalation ticket **INC0012345** and pinged the assigned reviewer (clinicalreview@example.com). Next-step SLA is 24 hours.

Behind that single answer, the Logic App workflow:

1. Looked up the PA (in production: a PBM PA platform or the payer's internal PA system).
2. Computed days outstanding against internal SLA.
3. Detected the SLA breach.
4. Opened a ServiceNow incident against the PA queue.
5. Notified the assigned reviewer in Teams.
6. Returned a clean summary the model can narrate.

## Why this pattern fits healthcare workloads

| Fit factor | Detail |
|---|---|
| **Deterministic orchestration** | Escalation rules (SLA thresholds, escalation targets) are business policy — Logic Apps expresses them as code-optional workflows, versioned in git, auditable. Not something you want a model to invent. |
| **Multi-system integration** | PA platform + ServiceNow + Teams (+ eventually contact-center telephony, EHR, member portal). The Azure Logic Apps 1,400+ connector catalog is the right tool for that job. |
| **Retryable, long-running** | HTTP retries, delays, and durable state are native to Logic Apps. The agent stays cheap and stateless. |
| **HIPAA-eligible services** | Both Microsoft Foundry Agent Service and Standard Logic Apps are HIPAA-eligible when configured on a BAA-covered subscription. |
| **Least-privilege identity** | Managed identity + a dedicated app registration + a scoped App Role — no shared secrets, no SAS keys, standard Zero-Trust posture. |

## What would change to productionize this

The demo is deliberately safe to run — no PHI, no real backends. To move it toward production for a healthcare payer or PBM:

### Data & connectors
- Replace the in-workflow synthetic dataset with the real PA platform (custom connector or HTTP action against the internal API).
- Replace the mock `httpbin.org` HTTP call with the **ServiceNow** connector and route to the correct assignment group.
- Replace the generic Teams incoming webhook with the **Microsoft Teams** connector (or Adaptive Card via Graph) targeting the reviewer's chat.
- Add a **Dataverse** or Cosmos DB write for audit trail so every escalation is logged independently of Logic Apps run history.

### Identity & security
- Move to **Private Endpoints** for the Logic App (`docs/vnet-hardening.md` covers this).
- Turn on **VNet integration** so outbound calls to PA / ServiceNow / Teams traverse the corporate network.
- Split App Roles: `PriorAuth.Read` (used here) vs `PriorAuth.Escalate` (write side) so the model only holds the read role and a separate service account performs the writes if regulators require separation of duties.
- **Customer-managed keys (CMK)** on storage and Logic Apps runtime.
- Enable **Microsoft Purview** sensitivity labels on Foundry project outputs; classify PA payloads as `Confidential — PHI (synthetic)` in the demo and `Highly Confidential — PHI` in production.

### Compliance & governance
- Ensure the Azure subscription is **BAA-covered** and the Foundry project is in a **HIPAA-eligible region**.
- Configure the Foundry model deployment with **abuse-monitoring opt-out** (documented process — required for PHI workloads).
- Retain workflow run history in a **long-term audit store** (Log Analytics with 7-year retention, or export to immutable Storage).
- Add **de-identification** on any free-text fields before they enter model context.
- Human-in-the-loop confirmation on any **write action** — the demo's Response includes an `escalated: true` boolean the agent can surface, but a production flow should require the user to explicitly confirm before the workflow performs the write.

### Model & agent
- Pin to a **content-filtered, PHI-safe** model deployment.
- Add **Foundry Toolbox** wrapping so the same PA workflow is shared across a family of clinical / member-service / provider-service agents, with centralized version and auth control.
- Add **evaluation datasets** in Foundry so regressions in the model's tool-call accuracy are caught before deployment.

## Related healthcare extensions (natural next demos)

Once this pattern is validated, the same skeleton drops in for:

- **Formulary lookup + alternative suggestion** (agent recommends a covered alternative when the requested drug isn't).
- **Rx refill / delivery tracking** (mail-order / specialty pharmacy inquiries).
- **Claims status + EOB retrieval** (payer side).
- **Care-gap outreach orchestration** (HEDIS quality measures, member outreach cadence).
- **Provider network / eligibility verification** (in-network status, benefit tiering, remaining deductible).
