# This job is disabled by default and must be destroyed immediately after use.
# Its password is injected through the Azure management plane after creation;
# secret values never enter Terraform configuration or state.
resource "azurerm_user_assigned_identity" "secret_bootstrap" {
  count = var.enable_secret_bootstrap ? 1 : 0

  name                = "${var.prefix}-secret-bootstrap-id"
  resource_group_name = azurerm_resource_group.hermes.name
  location            = azurerm_resource_group.hermes.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "secret_bootstrap" {
  count = var.enable_secret_bootstrap ? 1 : 0

  scope                = azurerm_key_vault.hermes.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.secret_bootstrap[0].principal_id
}

resource "azurerm_container_app_job" "secret_bootstrap" {
  count = var.enable_secret_bootstrap ? 1 : 0

  name                         = "${var.prefix}-secret-bootstrap"
  resource_group_name          = azurerm_resource_group.hermes.name
  location                     = azurerm_resource_group.hermes.location
  container_app_environment_id = azurerm_container_app_environment.hermes.id
  workload_profile_name        = "Consumption"
  replica_timeout_in_seconds   = 300
  replica_retry_limit          = 0
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.secret_bootstrap[0].id]
  }

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  template {
    container {
      name   = "bootstrap"
      image  = "docker.io/library/python@sha256:9ba6d8cbebf0fb6546ae71f2a1c14f6ffd2fdab83af7fa5669734ef30ad48844"
      cpu    = 0.25
      memory = "0.5Gi"

      command = ["python", "-c"]
      args = [<<-PYTHON
        import json
        import os
        import secrets
        import urllib.parse
        import urllib.request

        bootstrap_mode = os.environ["BOOTSTRAP_MODE"]
        secret_value = os.environ["BOOTSTRAP_SECRET_VALUE"]
        if len(secret_value) < 20:
          raise ValueError("Bootstrap secret must contain at least 20 characters")

        identity_query = urllib.parse.urlencode({
            "api-version": "2019-08-01",
            "resource": "https://vault.azure.net",
            "client_id": os.environ["AZURE_CLIENT_ID"],
        })
        token_request = urllib.request.Request(
            f"{os.environ['IDENTITY_ENDPOINT']}?{identity_query}",
            headers={"X-IDENTITY-HEADER": os.environ["IDENTITY_HEADER"]},
        )
        with urllib.request.urlopen(token_request, timeout=30) as response:
            token = json.load(response)["access_token"]

        vault_uri = os.environ["KEY_VAULT_URI"].rstrip("/")
        if bootstrap_mode == "dashboard":
          values = {
            "hermes-dashboard-password": secret_value,
            "hermes-dashboard-signing-secret": secrets.token_hex(48),
          }
        elif bootstrap_mode == "tailscale":
          values = {os.environ["TAILSCALE_SECRET_NAME"]: secret_value}
        else:
          raise ValueError("Unsupported bootstrap mode")
        for name, value in values.items():
            request = urllib.request.Request(
                f"{vault_uri}/secrets/{name}?api-version=7.4",
                data=json.dumps({"value": value}).encode(),
                method="PUT",
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
            )
            with urllib.request.urlopen(request, timeout=30) as response:
                if response.status not in (200, 201):
                    raise RuntimeError(f"Failed to write {name}")

        print("Requested Hermes secrets created successfully")
      PYTHON
      ]

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.secret_bootstrap[0].client_id
      }

      env {
        name  = "KEY_VAULT_URI"
        value = azurerm_key_vault.hermes.vault_uri
      }

      env {
        name  = "TAILSCALE_SECRET_NAME"
        value = var.tailscale_oauth_client_secret_name
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.secret_bootstrap,
    azurerm_private_endpoint.key_vault,
    azurerm_private_dns_zone_virtual_network_link.vault,
  ]
}