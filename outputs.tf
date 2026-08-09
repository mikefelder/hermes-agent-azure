output "app_url" {
  description = "Preferred HTTPS endpoint. Uses the Tailscale Service when enabled."
  value       = var.enable_tailscale ? local.tailscale_service_url : try("https://${azurerm_container_app.hermes.ingress[0].fqdn}", null)
}

output "app_fqdn" {
  description = "Container App ingress FQDN, or null when public ingress is disabled."
  value       = try(azurerm_container_app.hermes.ingress[0].fqdn, null)
}

output "tailscale_service_url" {
  description = "Stable Tailscale Service HTTPS endpoint, or null when Tailscale is disabled."
  value       = local.tailscale_service_url
}

output "api_server_url" {
  description = "OpenAI-compatible API base URL over Tailscale, or null when the API server is disabled."
  value       = local.api_server_url
}

output "container_app_name" {
  description = "Container App resource name for Azure CLI operations."
  value       = azurerm_container_app.hermes.name
}

output "resource_group_name" {
  description = "Resource group containing the Hermes Azure resources."
  value       = azurerm_resource_group.hermes.name
}

output "dashboard_username" {
  description = "Basic-auth username for the app/web gateway."
  value       = var.dashboard_username
}

output "foundry_endpoint" {
  description = "Microsoft Foundry account endpoint."
  value       = azurerm_cognitive_account.foundry.endpoint
}

output "foundry_base_url" {
  description = "OpenAI-style inference base URL Hermes uses (config.yaml model.base_url)."
  value       = local.foundry_base_url
}

output "model_deployment" {
  description = "Deployed model / deployment name (Hermes model.default)."
  value       = azurerm_cognitive_deployment.model.name
}

output "managed_identity_client_id" {
  description = "Client ID of the container's user-assigned managed identity."
  value       = azurerm_user_assigned_identity.hermes.client_id
}

output "container_image" {
  description = "Image the Container App runs."
  value       = local.container_image
}

output "key_vault_name" {
  description = "Dedicated Key Vault containing Hermes runtime secrets."
  value       = azurerm_key_vault.hermes.name
}

output "key_vault_uri" {
  description = "URI of the dedicated Hermes Key Vault."
  value       = azurerm_key_vault.hermes.vault_uri
}

output "secret_bootstrap_job_name" {
  description = "Temporary Key Vault bootstrap job name, or null when disabled."
  value       = try(azurerm_container_app_job.secret_bootstrap[0].name, null)
}

output "next_steps" {
  description = "What to do after apply."
  value       = <<-EOT
    1. Retrieve the dashboard password from the approved secret-management workflow.
         Key Vault: ${azurerm_key_vault.hermes.name}
         Secret:    hermes-dashboard-password
    2. Open the dashboard in a browser to confirm the login page loads:
         ${var.enable_tailscale ? local.tailscale_service_url : try(format("https://%s", azurerm_container_app.hermes.ingress[0].fqdn), "Ingress disabled")}
         Username:  ${var.dashboard_username}
         Password:  (from step 1)
    3. ${var.enable_api_server ? "Point API clients (iOS app, OpenAI SDKs) at the API server, not the dashboard:\n         Base URL:  ${local.api_server_url}\n         Auth:      Authorization: Bearer <${var.api_server_key_secret_name}>\n         Verify:    curl -H \"Authorization: Bearer $KEY\" ${local.api_server_url}/v1/models" : "API server disabled. Set enable_api_server = true to expose /v1/... over Tailscale."}
    4. To enable a messaging platform, add its Key Vault secret name to
       gateway_secret_names, populate that secret out of band, and re-apply.
    5. Tail logs:
         az containerapp logs show -n ${azurerm_container_app.hermes.name} -g ${azurerm_resource_group.hermes.name} --follow
  EOT
}
