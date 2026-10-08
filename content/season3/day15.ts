import { DayContent } from '../types';

export const day15: DayContent = {
  day: 15,
  title: "Memory Isolation & Regional Compliance (GDPR)",
  summary: "Prevent persistent agent memory from leaking across users, lines of business, or regional borders using Vertex AI Memory Bank scope partitioning, ADK ToolContext, and Cloud IAM Conditions.",
  tags: ["Memory Bank", "IAM Conditions", "GDPR", "Governance"],
  icon: "🔐",
  resourceLink: "https://docs.cloud.google.com/agent-builder/agent-engine/memory-bank/overview",
  codeSnippets: [
    {
      filename: "agent/agent.py",
      language: "python",
      code: `# 1. Bind memory scope from server-verified ToolContext (hidden from the LLM)
def _resolve_memory_context(tool_context: ToolContext) -> tuple[str, str, dict[str, str]]:
    verified_user_id = tool_context.user_id
    verified_lob = tool_context.state.get("tenant_lob")
    verified_region = tool_context.state.get("data_region", "us-central1")

    memory_bank_name = REGIONAL_MEMORY_BANKS[verified_region]
    # Exact-match dictionary partition:
    # - 'lob' is enforced by Cloud IAM Conditions (403 PERMISSION_DENIED)
    # - 'user_id' is enforced at runtime by Memory Bank exact scope matching
    scope = {
        "lob": str(verified_lob),
        "user_id": str(verified_user_id),
    }
    return verified_region, memory_bank_name, scope

def recall_memories(query: str, tool_context: ToolContext) -> dict:
    """Searches long-term memories for the current authenticated user."""
    region, memory_bank_name, scope = _resolve_memory_context(tool_context)
    client = vertexai.Client(project=PROJECT_ID, location=region)
    retrieved = client.agent_engines.memories.retrieve(
        name=memory_bank_name,
        scope=scope,
        similarity_search_params={"search_query": query, "top_k": 5},
    )
    return {"region": region, "scope": scope, "memories": [m.memory.fact for m in retrieved]}`
    },
    {
      filename: "terraform/main.tf",
      language: "hcl",
      code: `# 1. Regional Memory Banks (US: us-central1 | EU: europe-west1 for GDPR)
resource "google_vertex_ai_reasoning_engine" "eu_memory_bank" {
  provider     = google-beta
  project      = var.project_id
  region       = "europe-west1"
  display_name = "eu-banking-memory-bank-gdpr"
  spec {
    identity_type = "AGENT_IDENTITY"
  }
}

# 2. Line-of-Business & Regional RBAC via Cloud IAM Conditions
resource "google_project_iam_member" "us_retail_memory_isolation" {
  project = var.project_id
  role    = "roles/aiplatform.memoryUser"
  member  = "serviceAccount:\${google_service_account.us_retail_agent.email}"

  condition {
    title      = "US_Retail_Banking_Memory_Isolation"
    expression = "resource.name.startsWith('projects/\${local.project_number}/locations/us-central1/reasoningEngines/\${local.us_engine_id}') && api.getAttribute('aiplatform.googleapis.com/memoryScope', {})['lob'] == 'retail_banking'"
  }
}

resource "google_project_iam_member" "eu_retail_gdpr_memory_isolation" {
  project = var.project_id
  role    = "roles/aiplatform.memoryUser"
  member  = "serviceAccount:\${google_service_account.eu_retail_agent.email}"

  condition {
    title      = "EU_Retail_Banking_GDPR_Memory_Isolation"
    expression = "resource.name.startsWith('projects/\${local.project_number}/locations/europe-west1/reasoningEngines/\${local.eu_engine_id}') && api.getAttribute('aiplatform.googleapis.com/memoryScope', {})['lob'] == 'retail_banking'"
  }
}`
    },
    {
      filename: "quickstart.sh",
      language: "bash",
      code: `# 1. Provision US & EU Memory Banks and Conditional IAM RBAC boundaries:
chmod +x deploy.sh
./deploy.sh terraform-demo-agents

# 2. Run the 3-Act live verification demo (Namespace + LOB RBAC + GDPR):
python3 demo.py --act 1   # Act 1: Alice vs. Charlie user isolation
python3 demo.py --act 2   # Act 2: Wealth vs. Retail LOB 403 PERMISSION_DENIED
python3 demo.py --act 3   # Act 3: US vs. EU cross-border GDPR 403 PERMISSION_DENIED`
    }
  ],
  links: [
    {
      label: "Day 15 Code Kata",
      url: "https://github.com/chjoyce/advent-of-agents-s3-memory-isolation-day15",
      description: "Memory Isolation & Regional Compliance (GDPR) demo with Terraform and ADK."
    },
    {
      label: "Vertex AI Agent Memory Bank",
      url: "https://docs.cloud.google.com/agent-builder/agent-engine/memory-bank/overview",
      description: "Overview of persistent long-term memory in Vertex AI Agent Engine."
    },
    {
      label: "Memory Bank IAM Conditions (`memoryScope`)",
      url: "https://docs.cloud.google.com/agent-builder/agent-engine/memory-bank/Quickstart-api",
      description: "Enforce fine-grained RBAC on Memory Bank scopes using Cloud IAM Conditions."
    }
  ],
  description: `
**Day 15 of Google's Advent of Agents — Season 3**

When enterprise agents store long-term memories across sessions, a naive shared memory store creates two critical governance failures: **cross-tenant / cross-user data leakage** (via prompt injection or over-privileged credentials) and **cross-border data residency violations (GDPR)**.

**3-Layer Defense-in-Depth for Agent Memory**

- **1. Strict Runtime Namespace Partitioning (\`scope\` + ADK \`ToolContext\`)**: Every memory write and retrieval in Vertex AI Memory Bank requires an exact-match \`scope\` dictionary (up to 5 key-value pairs, e.g. \`{"lob": "retail_banking", "user_id": "alice@bank.com"}\`). By reading \`user_id\` and \`tenant_lob\` from ADK's server-populated \`ToolContext\` (which is automatically stripped from the LLM's \`FunctionDeclaration\` schema), a prompt-injected model cannot forge another user's scope.
- **2. Line-of-Business RBAC via Cloud IAM Conditions**: Bind \`roles/aiplatform.memoryUser\` with the CEL condition \`api.getAttribute('aiplatform.googleapis.com/memoryScope', {})['lob'] == 'retail_banking'\` so a Wealth Management agent receives an immediate \`403 PERMISSION_DENIED\` from Cloud IAM if it attempts to read or poison Retail Banking memories.
- **3. Regional Data Residency & GDPR Boundaries**: Provision regional Memory Banks (\`us-central1\` vs. \`europe-west1\`) and combine \`resource.name.startsWith('projects/.../locations/europe-west1/reasoningEngines/...')\` with \`memoryScope\` IAM conditions so European customer memories never cross regional borders.
`,
  videoURL: null
};
