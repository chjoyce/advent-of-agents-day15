terraform {
  required_version = ">= 1.5.0"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.0.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.us_region
}

provider "google-beta" {
  project = var.project_id
  region  = var.us_region
}

# ==============================================================================
# 1. Enable Required APIs & Look Up Project Number
# ==============================================================================
locals {
  required_apis = [
    "aiplatform.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.required_apis)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

data "google_project" "current" {
  project_id = var.project_id
  depends_on = [google_project_service.apis]
}

# ==============================================================================
# 2. Regional Agent Memory Banks (US: us-central1 | EU: europe-west1 for GDPR)
# ==============================================================================
# If `existing_us_engine_id` is passed, reuse that existing Reasoning Engine in
# us-central1; otherwise provision a dedicated US Memory Bank.
resource "google_vertex_ai_reasoning_engine" "us_memory_bank" {
  count        = var.existing_us_engine_id == "" ? 1 : 0
  provider     = google-beta
  project      = var.project_id
  region       = var.us_region
  display_name = "us-banking-memory-bank"
  description  = "US Regional Memory Bank (us-central1) with LOB & User Namespace Partitioning"

  spec {
    identity_type = "AGENT_IDENTITY"
  }

  depends_on = [google_project_service.apis]
}

# Dedicated EU Memory Bank in europe-west1 (Belgium) so European users' memories
# physically reside inside the EU boundary for GDPR data residency compliance.
resource "google_vertex_ai_reasoning_engine" "eu_memory_bank" {
  provider     = google-beta
  project      = var.project_id
  region       = var.eu_region
  display_name = "eu-banking-memory-bank-gdpr"
  description  = "EU Regional Memory Bank (europe-west1) for GDPR Data Residency & Regional RBAC"

  spec {
    identity_type = "AGENT_IDENTITY"
  }

  depends_on = [google_project_service.apis]
}

locals {
  project_number = data.google_project.current.number

  raw_us_engine = var.existing_us_engine_id != "" ? var.existing_us_engine_id : google_vertex_ai_reasoning_engine.us_memory_bank[0].name
  us_engine_id  = element(split("/", local.raw_us_engine), length(split("/", local.raw_us_engine)) - 1)
  eu_engine_id  = element(split("/", google_vertex_ai_reasoning_engine.eu_memory_bank.name), length(split("/", google_vertex_ai_reasoning_engine.eu_memory_bank.name)) - 1)

  # Vertex AI Memory Bank evaluates Cloud IAM Conditions against the canonical
  # project-number-based ReasoningEngine resource name:
  # projects/{PROJECT_NUMBER}/locations/{LOCATION}/reasoningEngines/{ENGINE_ID}
  us_memory_bank_resource_name = "projects/${local.project_number}/locations/${var.us_region}/reasoningEngines/${local.us_engine_id}"
  eu_memory_bank_resource_name = "projects/${local.project_number}/locations/${var.eu_region}/reasoningEngines/${local.eu_engine_id}"
}

# ==============================================================================
# 3. Regional & Line-of-Business Agent Principals (Service Accounts)
# ==============================================================================
resource "google_service_account" "us_retail_agent" {
  project      = var.project_id
  account_id   = "us-retail-agent-sa"
  display_name = "US Retail Banking Agent (us-central1 / lob=retail_banking)"
  description  = "Can only read/write memories in us-central1 where scope.lob == 'retail_banking'"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "us_wealth_agent" {
  project      = var.project_id
  account_id   = "us-wealth-agent-sa"
  display_name = "US Wealth Management Agent (us-central1 / lob=wealth_management)"
  description  = "Can only read/write memories in us-central1 where scope.lob == 'wealth_management'"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "eu_retail_agent" {
  project      = var.project_id
  account_id   = "eu-retail-agent-sa"
  display_name = "EU Retail Banking Agent (europe-west1 / lob=retail_banking)"
  description  = "GDPR Regional Boundary: Can only read/write memories in europe-west1 where scope.lob == 'retail_banking'"
  depends_on   = [google_project_service.apis]
}

# ==============================================================================
# 4. Strict Namespace & Regional RBAC Boundaries via Cloud IAM Conditions
# ==============================================================================
# Each principal receives `roles/aiplatform.memoryUser` gated by a CEL condition
# that checks BOTH:
#   1. Regional resource path (`resource.name.startsWith(...)`)
#   2. Memory scope attribute (`api.getAttribute('aiplatform.googleapis.com/memoryScope', {})['lob']`)

# Binding A: US Retail Banking -> us-central1 Memory Bank + lob == 'retail_banking'
resource "google_project_iam_member" "us_retail_memory_isolation" {
  project = var.project_id
  role    = "roles/aiplatform.memoryUser"
  member  = "serviceAccount:${google_service_account.us_retail_agent.email}"

  condition {
    title       = "US_Retail_Banking_Memory_Isolation"
    description = "Restricts memory access to the us-central1 Memory Bank and scope.lob == retail_banking"
    expression  = "resource.name.startsWith('${local.us_memory_bank_resource_name}') && api.getAttribute('aiplatform.googleapis.com/memoryScope', {})['lob'] == 'retail_banking'"
  }
}

# Binding B: US Wealth Management -> us-central1 Memory Bank + lob == 'wealth_management'
resource "google_project_iam_member" "us_wealth_memory_isolation" {
  project = var.project_id
  role    = "roles/aiplatform.memoryUser"
  member  = "serviceAccount:${google_service_account.us_wealth_agent.email}"

  condition {
    title       = "US_Wealth_Management_Memory_Isolation"
    description = "Restricts memory access to the us-central1 Memory Bank and scope.lob == wealth_management"
    expression  = "resource.name.startsWith('${local.us_memory_bank_resource_name}') && api.getAttribute('aiplatform.googleapis.com/memoryScope', {})['lob'] == 'wealth_management'"
  }
}

# Binding C: EU Retail Banking (GDPR) -> europe-west1 Memory Bank + lob == 'retail_banking'
resource "google_project_iam_member" "eu_retail_gdpr_memory_isolation" {
  project = var.project_id
  role    = "roles/aiplatform.memoryUser"
  member  = "serviceAccount:${google_service_account.eu_retail_agent.email}"

  condition {
    title       = "EU_Retail_Banking_GDPR_Memory_Isolation"
    description = "GDPR Regional Boundary: Restricts memory access to the europe-west1 Memory Bank and scope.lob == retail_banking"
    expression  = "resource.name.startsWith('${local.eu_memory_bank_resource_name}') && api.getAttribute('aiplatform.googleapis.com/memoryScope', {})['lob'] == 'retail_banking'"
  }
}

# Also bind the SPIFFE Agent Identities of the regional Reasoning Engines to their
# respective regional + LOB boundaries:
resource "google_project_iam_member" "us_spiffe_memory_isolation" {
  count   = var.existing_us_engine_id == "" ? 1 : 0
  project = var.project_id
  role    = "roles/aiplatform.memoryUser"
  member  = "principal://${google_vertex_ai_reasoning_engine.us_memory_bank[0].spec[0].effective_identity}"

  condition {
    title       = "US_SPIFFE_Retail_Memory_Isolation"
    description = "SPIFFE Agent Identity restricted to us-central1 Memory Bank and scope.lob == retail_banking"
    expression  = "resource.name.startsWith('${local.us_memory_bank_resource_name}') && api.getAttribute('aiplatform.googleapis.com/memoryScope', {})['lob'] == 'retail_banking'"
  }
}

resource "google_project_iam_member" "eu_spiffe_gdpr_memory_isolation" {
  project = var.project_id
  role    = "roles/aiplatform.memoryUser"
  member  = "principal://${google_vertex_ai_reasoning_engine.eu_memory_bank.spec[0].effective_identity}"

  condition {
    title       = "EU_SPIFFE_GDPR_Memory_Isolation"
    description = "SPIFFE Agent Identity restricted to europe-west1 Memory Bank and scope.lob == retail_banking"
    expression  = "resource.name.startsWith('${local.eu_memory_bank_resource_name}') && api.getAttribute('aiplatform.googleapis.com/memoryScope', {})['lob'] == 'retail_banking'"
  }
}
