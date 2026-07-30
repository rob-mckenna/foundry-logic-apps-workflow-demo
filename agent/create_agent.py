"""Create (or update) the Foundry agent with the Logic Apps workflow as an OpenAPI tool.

Reads the OpenAPI spec next to `workflows/prior-auth-status-check/openapi.yaml`,
substitutes ${LOGIC_APP_HOSTNAME} and ${TENANT_ID}, and registers a
PromptAgentDefinition with a single OpenApiTool using managed-identity auth.

Requires (via .env):
    FOUNDRY_PROJECT_ENDPOINT
    MODEL_DEPLOYMENT_NAME
    LOGIC_APP_HOSTNAME
    TENANT_ID
    AUDIENCE
    AGENT_NAME
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from string import Template

import yaml
from dotenv import load_dotenv
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    OpenApiTool,
    OpenApiFunctionDefinition,
    OpenApiManagedAuthDetails,
    OpenApiManagedSecurityScheme,
    PromptAgentDefinition,
)
from azure.identity import DefaultAzureCredential


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OPENAPI_PATH = REPO_ROOT / "workflows" / "prior-auth-status-check" / "openapi.yaml"


def _openapi_path() -> Path:
    """Resolve after load_dotenv has populated the environment."""
    return Path(os.environ.get("OPENAPI_PATH", str(DEFAULT_OPENAPI_PATH)))

AGENT_INSTRUCTIONS = """You are a prior authorization assistant for a pharmacy benefit manager (PBM).

When a user asks about the status of a prior authorization, extract the PA ID
(format: PA-YYYY-NNNNN) and call the `check_prior_auth_status` tool. Summarize
the tool's response in plain language for a clinical care coordinator:

- State the drug, member ID, and current status.
- Report days outstanding.
- If the PA was escalated, clearly call out the escalation ticket number and
  the next-step SLA in hours.
- If the PA was denied, surface the denial reason verbatim.

Never fabricate PA IDs, member IDs, drug names, or ticket numbers. If the user
doesn't provide a PA ID, ask for one before calling the tool.

All data in this system is synthetic — this is a technical demonstration.
"""


def _load_openapi() -> dict:
    path = _openapi_path()
    print(f"Loading OpenAPI spec from: {path}")
    text = path.read_text(encoding="utf-8")
    substituted = Template(text).safe_substitute(
        LOGIC_APP_HOSTNAME=os.environ.get("LOGIC_APP_HOSTNAME", ""),
        TENANT_ID=os.environ.get("TENANT_ID", ""),
    )
    return yaml.safe_load(substituted)


def main() -> int:
    load_dotenv()
    for var in ("FOUNDRY_PROJECT_ENDPOINT", "MODEL_DEPLOYMENT_NAME",
                "LOGIC_APP_HOSTNAME", "TENANT_ID", "AUDIENCE", "AGENT_NAME"):
        if not os.environ.get(var):
            print(f"ERROR: {var} not set (check your .env).", file=sys.stderr)
            return 2

    spec = _load_openapi()

    client = AIProjectClient(
        endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        credential=DefaultAzureCredential(),
    )

    tool = OpenApiTool(
        openapi=OpenApiFunctionDefinition(
            name="check_prior_auth_status",
            description=(
                "Look up a prior authorization by ID and, if it has been "
                "Pending more than 3 business days, escalate it. Returns "
                "current status, days outstanding, and escalation info."
            ),
            spec=spec,
            auth=OpenApiManagedAuthDetails(
                security_scheme=OpenApiManagedSecurityScheme(
                    audience=os.environ["AUDIENCE"],
                ),
            ),
        ),
    )

    agent = client.agents.create_version(
        agent_name=os.environ["AGENT_NAME"],
        definition=PromptAgentDefinition(
            model=os.environ["MODEL_DEPLOYMENT_NAME"],
            instructions=AGENT_INSTRUCTIONS,
            tools=[tool],
        ),
    )

    print(f"Created agent: {agent.name}")
    print(f"  Version:     {getattr(agent, 'version', 'n/a')}")
    print(f"  Model:       {os.environ['MODEL_DEPLOYMENT_NAME']}")
    print(f"  Tool:        check_prior_auth_status (audience: {os.environ['AUDIENCE']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
