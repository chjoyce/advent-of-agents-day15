output "project_id" {
  description = "Google Cloud project ID."
  value       = var.project_id
}

output "project_number" {
  description = "Google Cloud project number."
  value       = local.project_number
}

output "us_region" {
  description = "US Memory Bank region."
  value       = var.us_region
}

output "eu_region" {
  description = "EU (GDPR) Memory Bank region."
  value       = var.eu_region
}

output "us_engine_id" {
  description = "US Reasoning Engine / Memory Bank numeric ID."
  value       = local.us_engine_id
}

output "eu_engine_id" {
  description = "EU Reasoning Engine / Memory Bank numeric ID."
  value       = local.eu_engine_id
}

output "us_memory_bank_name" {
  description = "Full resource name of the US Memory Bank in us-central1."
  value       = local.us_memory_bank_resource_name
}

output "eu_memory_bank_name" {
  description = "Full resource name of the EU Memory Bank in europe-west1."
  value       = local.eu_memory_bank_resource_name
}

output "us_retail_sa_email" {
  description = "Service Account email for US Retail Banking Agent."
  value       = google_service_account.us_retail_agent.email
}

output "us_wealth_sa_email" {
  description = "Service Account email for US Wealth Management Agent."
  value       = google_service_account.us_wealth_agent.email
}

output "eu_retail_sa_email" {
  description = "Service Account email for EU Retail Banking Agent (GDPR)."
  value       = google_service_account.eu_retail_agent.email
}
