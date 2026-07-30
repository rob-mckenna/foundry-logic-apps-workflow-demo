"""Delete the agent version created by create_agent.py."""

from __future__ import annotations

import os
import sys

from dotenv import load_dotenv
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential


def main() -> int:
    load_dotenv()
    for var in ("FOUNDRY_PROJECT_ENDPOINT", "AGENT_NAME"):
        if not os.environ.get(var):
            print(f"ERROR: {var} not set (check your .env).", file=sys.stderr)
            return 2

    client = AIProjectClient(
        endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        credential=DefaultAzureCredential(),
    )

    name = os.environ["AGENT_NAME"]
    try:
        client.agents.delete(agent_name=name)
        print(f"Deleted agent: {name}")
    except Exception as exc:  # noqa: BLE001
        print(f"Could not delete agent {name!r}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
