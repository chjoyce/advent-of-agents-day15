variable "project_id" {
  type        = string
  description = "Google Cloud project ID."
}

variable "us_region" {
  type        = string
  description = "US region for North America Memory Bank."
  default     = "us-central1"
}

variable "eu_region" {
  type        = string
  description = "EU region for GDPR-compliant European Memory Bank."
  default     = "europe-west1"
}

variable "existing_us_engine_id" {
  type        = string
  description = "Optional existing Reasoning Engine ID in us-central1. Leave empty to provision a dedicated US Memory Bank."
  default     = ""
}
