#!/usr/bin/env bash
# ==============================================================================
# Turnkey Setup & Deployment for Day 15: Memory Isolation & Regional Compliance
# ==============================================================================
# Usage:
#   ./deploy.sh [PROJECT_ID] [EXISTING_US_ENGINE_ID]
#
# Example:
#   ./deploy.sh terraform-demo-agents
# ==============================================================================

set -euo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-terraform-demo-agents}}"
EXISTING_US_ENGINE_ID="${2:-${EXISTING_US_ENGINE_ID:-}}"
US_REGION="${US_REGION:-us-central1}"
EU_REGION="${EU_REGION:-europe-west1}"
TF_BUCKET="${PROJECT_ID}-terraform-state"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================================================"
echo " Day 15: Memory Isolation & Regional Compliance (GDPR) Deployment"
echo "------------------------------------------------------------------------"
echo " Project ID : ${PROJECT_ID}"
echo " US Region  : ${US_REGION}"
echo " EU Region  : ${EU_REGION} (GDPR Data Residency Boundary)"
echo " TF Bucket  : gs://${TF_BUCKET}"
echo "========================================================================"

# ------------------------------------------------------------------------------
# 0. Verify gcloud & Application Default Credentials (ADC)
# ------------------------------------------------------------------------------
echo "-> Verifying gcloud & Application Default Credentials..."
if ! gcloud auth print-access-token >/dev/null 2>&1; then
  echo "ERROR: Your gcloud session needs reauthentication."
  echo "Please run:  gcloud auth login && gcloud auth application-default login"
  exit 1
fi
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "ERROR: Your Application Default Credentials (ADC) need reauthentication."
  echo "Please run:  gcloud auth application-default login"
  exit 1
fi

gcloud config set project "${PROJECT_ID}" >/dev/null
ACTIVE_ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
echo "   Authenticated as: ${ACTIVE_ACCOUNT}"

# ------------------------------------------------------------------------------
# 1. Enable Required APIs
# ------------------------------------------------------------------------------
echo "-> [1/5] Enabling required Google Cloud APIs..."
gcloud services enable \
  aiplatform.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  storage.googleapis.com \
  --project="${PROJECT_ID}"

# ------------------------------------------------------------------------------
# 2. Auto-detect existing US Reasoning Engine in `terraform-demo-agents` (if any)
# ------------------------------------------------------------------------------
if [[ -z "${EXISTING_US_ENGINE_ID}" ]]; then
  echo "-> [2/5] Checking for existing Reasoning Engine in ${US_REGION}..."
  TOKEN="$(gcloud auth print-access-token)"
  EXISTING_US_ENGINE_ID="$(
    curl -s -H "Authorization: Bearer ${TOKEN}" \
      "https://${US_REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${US_REGION}/reasoningEngines" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
engines = data.get('reasoningEngines', [])
# Prefer 'terraform-demo-agent' or 'us-banking-memory-bank' if present
for preferred in ('terraform-demo-agent', 'us-banking-memory-bank'):
    for e in engines:
        if e.get('displayName') == preferred:
            print(e['name'].split('/')[-1])
            sys.exit(0)
if engines:
    print(engines[0]['name'].split('/')[-1])
" 2>/dev/null || true
  )"
  if [[ -n "${EXISTING_US_ENGINE_ID}" ]]; then
    echo "   Found existing US Reasoning Engine in ${US_REGION}: ${EXISTING_US_ENGINE_ID} (reusing)"
  else
    echo "   No existing US Reasoning Engine found; Terraform will provision 'us-banking-memory-bank'."
  fi
else
  echo "-> [2/5] Using provided US Reasoning Engine ID: ${EXISTING_US_ENGINE_ID}"
fi

# ------------------------------------------------------------------------------
# 3. Ensure GCS Bucket for Terraform State Exists
# ------------------------------------------------------------------------------
echo "-> [3/5] Ensuring Terraform state bucket gs://${TF_BUCKET} exists..."
if ! gcloud storage buckets describe "gs://${TF_BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${TF_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${US_REGION}" \
    --uniform-bucket-level-access
  gcloud storage buckets update "gs://${TF_BUCKET}" --versioning
else
  echo "   Bucket gs://${TF_BUCKET} already exists."
fi

# ------------------------------------------------------------------------------
# 4. Run Terraform to Provision Regional Memory Banks & Conditional IAM RBAC
# ------------------------------------------------------------------------------
echo "-> [4/5] Applying Terraform configuration..."
cd "${REPO_ROOT}/terraform"

terraform init -reconfigure \
  -backend-config="bucket=${TF_BUCKET}" \
  -backend-config="prefix=memory-isolation-day15/state"

terraform apply -auto-approve \
  -var="project_id=${PROJECT_ID}" \
  -var="us_region=${US_REGION}" \
  -var="eu_region=${EU_REGION}" \
  -var="existing_us_engine_id=${EXISTING_US_ENGINE_ID}"

terraform output -json > "${REPO_ROOT}/deployment_outputs.json"
cd "${REPO_ROOT}"

# ------------------------------------------------------------------------------
# 5. Grant Keyless Service Account Impersonation to Active User for Live Demo
# ------------------------------------------------------------------------------
echo "-> [5/5] Granting roles/iam.serviceAccountTokenCreator on demo SAs to ${ACTIVE_ACCOUNT}..."
MEMBER_PREFIX="user"
if [[ "${ACTIVE_ACCOUNT}" == *.gserviceaccount.com ]]; then
  MEMBER_PREFIX="serviceAccount"
fi

for SA_NAME in us-retail-agent-sa us-wealth-agent-sa eu-retail-agent-sa; do
  SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
    --project="${PROJECT_ID}" \
    --member="${MEMBER_PREFIX}:${ACTIVE_ACCOUNT}" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --quiet >/dev/null
done

echo ""
echo "========================================================================"
echo " Deployment Complete!"
echo "------------------------------------------------------------------------"
echo " Outputs saved to: ${REPO_ROOT}/deployment_outputs.json"
echo " Run the 3-Act live verification demo:"
echo "   python3 demo.py"
echo "========================================================================"
