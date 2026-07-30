"""Run all 5 demo scenarios end-to-end."""

import os
import sys

from dotenv import load_dotenv
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential


PROMPTS = [
    ("Escalation (Pending, 7 days)", "What's the status of PA-2026-88425?"),
    ("Approved",                     "Check PA-2026-88422 for me."),
    ("Denied",                       "Why was PA-2026-88423 denied?"),
    ("Within SLA (Pending, 1 day)",  "Any update on PA-2026-88424?"),
    ("Not found",                    "Status of PA-2026-99999?"),
]


def main() -> int:
    load_dotenv()
    project = AIProjectClient(
        endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        credential=DefaultAzureCredential(),
    )
    openai = project.get_openai_client()
    for label, prompt in PROMPTS:
        print(f"\n\n===== {label} =====")
        print(f"User: {prompt}")
        resp = openai.responses.create(
            input=prompt,
            extra_body={
                "agent_reference": {
                    "name": os.environ["AGENT_NAME"],
                    "type": "agent_reference",
                },
            },
        )
        print(f"Agent: {resp.output_text}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
