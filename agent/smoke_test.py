"""One-shot smoke test: ask about PA-2026-88421 and print the response."""

import os
import sys

from dotenv import load_dotenv
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential


def main() -> int:
    load_dotenv()
    project = AIProjectClient(
        endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        credential=DefaultAzureCredential(),
    )
    openai = project.get_openai_client()
    resp = openai.responses.create(
        input="What's the status of PA-2026-88421? Give me a concise summary.",
        extra_body={
            "agent_reference": {
                "name": os.environ["AGENT_NAME"],
                "type": "agent_reference",
            },
        },
    )
    print("=== Agent output ===")
    print(resp.output_text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
