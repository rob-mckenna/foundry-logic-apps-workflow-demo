"""Interactive REPL against the prior-auth-assistant agent."""

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

    project = AIProjectClient(
        endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        credential=DefaultAzureCredential(),
    )
    openai = project.get_openai_client()

    agent_name = os.environ["AGENT_NAME"]
    print(f"Connected to {agent_name}. Type your prompt, or 'exit' to quit.\n")

    while True:
        try:
            prompt = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if not prompt:
            continue
        if prompt.lower() in {"exit", "quit"}:
            return 0

        response = openai.responses.create(
            input=prompt,
            extra_body={
                "agent_reference": {"name": agent_name, "type": "agent_reference"},
            },
        )
        print(f"\n{response.output_text}\n")


if __name__ == "__main__":
    sys.exit(main())
