import os
from google.adk.agents import LlmAgent
from google.adk.agents.callback_context import CallbackContext
from google.adk.tools import ToolContext
import vertexai

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "")

# Regional Memory Bank (Reasoning Engine) resource names:
# - US_MEMORY_BANK_NAME: projects/{PROJECT_NUMBER}/locations/us-central1/reasoningEngines/{US_ENGINE_ID}
# - EU_MEMORY_BANK_NAME: projects/{PROJECT_NUMBER}/locations/europe-west1/reasoningEngines/{EU_ENGINE_ID}
REGIONAL_MEMORY_BANKS = {
    "us-central1": os.environ.get("US_MEMORY_BANK_NAME", ""),
    "europe-west1": os.environ.get("EU_MEMORY_BANK_NAME", ""),
}


def _resolve_memory_context(tool_context: ToolContext) -> tuple[str, str, dict[str, str]]:
    """Extracts verified region, Memory Bank resource name, and scope from ToolContext.

    CRITICAL SECURITY INVARIANT:
    `tool_context` is injected by the ADK Runner from the authenticated server
    session and is automatically stripped from the LLM's FunctionDeclaration schema.
    The LLM cannot see, forge, or override `user_id`, `tenant_lob`, or `data_region`.
    """
    verified_user_id = tool_context.user_id
    verified_lob = tool_context.state.get("tenant_lob")
    verified_region = tool_context.state.get("data_region", "us-central1")

    if not verified_user_id or not verified_lob:
        raise PermissionError(
            "Missing verified user_id or tenant_lob in server session context."
        )

    memory_bank_name = REGIONAL_MEMORY_BANKS.get(verified_region)
    if not memory_bank_name:
        raise ValueError(
            f"No regional Memory Bank configured for data_region={verified_region!r}"
        )

    # Composite scope dictionary:
    # - 'lob' is enforced at the infrastructure layer by Cloud IAM Conditions
    #   (api.getAttribute('aiplatform.googleapis.com/memoryScope', {})['lob'])
    # - 'user_id' is enforced at the runtime layer by exact-match dictionary
    #   partitioning inside Vertex AI Memory Bank.
    scope = {
        "lob": str(verified_lob),
        "user_id": str(verified_user_id),
    }
    return verified_region, memory_bank_name, scope


def recall_memories(query: str, tool_context: ToolContext) -> dict:
    """Searches long-term memories for the current authenticated user.

    Args:
        query: Semantic search query describing what to recall about the user.
    """
    region, memory_bank_name, scope = _resolve_memory_context(tool_context)
    client = vertexai.Client(project=PROJECT_ID, location=region)

    retrieved = client.agent_engines.memories.retrieve(
        name=memory_bank_name,
        scope=scope,
        similarity_search_params={
            "search_query": query,
            "top_k": 5,
        },
    )
    facts = [
        item.memory.fact
        for item in retrieved
        if item.memory and item.memory.fact
    ]
    return {
        "region": region,
        "scope": scope,
        "count": len(facts),
        "memories": facts,
    }


def save_memory_fact(fact: str, tool_context: ToolContext) -> dict:
    """Saves a preference or fact to the current authenticated user's Memory Bank.

    Args:
        fact: A concise, self-contained fact about the user to remember across sessions.
    """
    region, memory_bank_name, scope = _resolve_memory_context(tool_context)
    client = vertexai.Client(project=PROJECT_ID, location=region)

    operation = client.agent_engines.memories.create(
        name=memory_bank_name,
        fact=fact,
        scope=scope,
    )
    memory_name = operation.response.name if operation.response else operation.name
    return {
        "status": "saved",
        "region": region,
        "scope": scope,
        "memory_name": memory_name,
    }


def auto_consolidate_turn_memory(callback_context: CallbackContext) -> None:
    """Optional after_agent_callback that triggers async memory extraction."""
    session = callback_context._invocation_context.session
    verified_user_id = session.user_id
    verified_lob = session.state.get("tenant_lob")
    verified_region = session.state.get("data_region", "us-central1")
    memory_bank_name = REGIONAL_MEMORY_BANKS.get(verified_region)

    if not (verified_user_id and verified_lob and memory_bank_name):
        return

    events = [
        {"content": event.content.model_dump(exclude_none=True)}
        for event in session.events[-2:]
        if event.content and event.content.parts
    ]
    if not events:
        return

    client = vertexai.Client(project=PROJECT_ID, location=verified_region)
    client.agent_engines.memories.generate(
        name=memory_bank_name,
        direct_contents_source={"events": events},
        scope={
            "lob": str(verified_lob),
            "user_id": str(verified_user_id),
        },
        config={"wait_for_completion": False},
    )


root_agent = LlmAgent(
    name="regional_Isolated_banking_agent",
    model="gemini-2.5-flash",
    description=(
        "Enterprise banking assistant with strict Memory Bank namespace "
        "partitioning and regional RBAC (GDPR) compliance boundaries."
    ),
    instruction=(
        "You are an enterprise banking assistant. "
        "Use `recall_memories` to look up facts about the current user before answering "
        "personalized questions, and use `save_memory_fact` when the user shares a new "
        "preference or account detail they want remembered. "
        "You can only access memories belonging to the currently authenticated user "
        "within their Line of Business and geographic data region."
    ),
    tools=[recall_memories, save_memory_fact],
)
