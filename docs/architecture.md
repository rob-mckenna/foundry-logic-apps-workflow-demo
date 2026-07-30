# Architecture

## Component diagram

```mermaid
flowchart LR
    U[User / Pharmacist / Care Coordinator]
    subgraph Foundry [Microsoft Foundry Agent Service]
        A[prior-auth-assistant<br/>gpt-4.1-mini<br/>PromptAgentDefinition]
        MI[(User-Assigned<br/>Managed Identity)]
        T[OpenApiTool<br/>audience: api://prior-auth-api]
        A --- T
        A --- MI
    end
    EAD[(Microsoft Entra ID<br/>app: prior-auth-api<br/>App Role: PriorAuth.Read)]
    subgraph LA [Standard Logic App WS1]
        R[Request trigger<br/>Authorization Policy:<br/>iss / aud / roles]
        S[Switch on priorAuthId]
        C{status == Pending<br/>AND days > 3?}
        E1[POST mock<br/>ServiceNow incident]
        E2[Notify reviewer<br/>Teams webhook]
        RES[Response]
        R --> S --> C
        C -- yes --> E1 --> E2 --> RES
        C -- no --> RES
    end

    U --> A
    T -- Entra token<br/>Bearer --> R
    MI -. app-role assigned .- EAD
    R -. validates token against .- EAD
```

## Token flow

```mermaid
sequenceDiagram
    autonumber
    participant User
    participant Agent as Foundry Agent
    participant MI as Foundry UAMI
    participant AAD as Entra ID
    participant LA as Standard Logic App
    User->>Agent: "Status of PA-2026-88421?"
    Agent->>Agent: Decides to call check_prior_auth_status tool
    Agent->>MI: Acquire token (audience = api://prior-auth-api)
    MI->>AAD: client_credentials + federated MI cert
    AAD-->>MI: JWT (aud=api://prior-auth-api, roles=[PriorAuth.Read])
    MI-->>Agent: token
    Agent->>LA: POST /workflows/.../triggers/manual/invoke<br/>Authorization: Bearer <jwt>
    LA->>LA: Authorization Policy checks iss, aud, roles
    LA->>LA: Runs workflow
    LA-->>Agent: 200 { priorAuthId, status, escalated, summary, ... }
    Agent-->>User: Natural-language summary
```

## Why each piece exists

| Piece | Role | Why not simpler? |
|---|---|---|
| **Standard Logic App (WS1)** | Hosts the workflow. | Consumption doesn't support per-trigger AAD Authorization Policies as cleanly, and can't run inside a VNet. Standard is the production path. |
| **User-assigned Managed Identity** on the Foundry project | Provides the caller identity. | System-assigned would work but rebuilds the SP if the project is recreated, breaking role assignments. UAMI survives. |
| **Entra app registration `prior-auth-api`** | Represents the Logic App's API surface. Owns the audience (App ID URI) and the App Role `PriorAuth.Read`. | You could reuse `https://management.azure.com/` as the audience, but that gives the token broader implicit meaning. A dedicated app registration is the least-privilege pattern. |
| **App Role `PriorAuth.Read`** assigned to the Foundry UAMI | Populates the `roles` claim on the token. | Without a role assignment, the token would have no `roles` claim and the Authorization Policy would reject it. |
| **Trigger-level Authorization Policy** (not App Service Easy Auth) | Per-workflow claim checks, closer to Logic Apps idioms. | Easy Auth is site-wide — heavier hammer if the Logic App eventually hosts multiple workflows with different callers. |
| **OpenAPI tool** on the Foundry agent | Contract that lets the model know when and how to call the workflow. | Foundry classic's "Logic Apps action" wizard is deprecated; OpenAPI is the current GA path. |

## Data flow within the workflow

1. **Request trigger** receives `{ priorAuthId, memberId?, requestingProvider? }`.
2. **Compose `paDataset`** — synthetic in-workflow JSON array (5 sample PAs).
3. **Filter Array** — find matching record for `priorAuthId`.
4. **Condition — Found?**
    - **False**: Response 404 with `{ error: "PA not found" }`.
    - **True**: continue.
5. **Compose `daysOutstanding`** — `div(sub(ticks(utcNow()), ticks(pa.submittedDate)), 864000000000)`.
6. **Condition — Should escalate?** (`status == 'Pending' && daysOutstanding > 3`)
    - **True**:
        1. **HTTP** POST to mock ServiceNow endpoint (`https://httpbin.org/post` in demo).
        2. **HTTP** POST to Teams incoming webhook (URL provided at deploy time).
        3. **Set variable `escalationTicket`** from mock response.
    - **False**: `escalationTicket = null`.
7. **Response** — 200 with the composed summary payload.

The scripted mocks (steps 6.i-6.ii) are deliberately trivial. Replacing them with real ServiceNow + Teams instances is a `docs/healthcare-scenario.md` production step.
