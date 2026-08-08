data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  suffix = random_string.suffix.result

  # Foundry custom subdomain — required for Entra ID token auth. Drives the
  # OpenAI-style inference host used by Hermes' azure-foundry provider.
  foundry_name     = "${var.prefix}-foundry-${local.suffix}"
  foundry_base_url = "https://${local.foundry_name}.openai.azure.com/openai/v1"

  acr_name       = "${var.prefix}acr${local.suffix}"
  storage_name   = "${var.prefix}st${local.suffix}"
  key_vault_name = "${var.prefix}-kv-${local.suffix}"

  # Named ingress allow rules (adding any Allow rule denies all other sources).
  ingress_allow = var.allow_unrestricted_ingress ? {} : {
    for i, cidr in var.allowed_ingress_ips : "allow-${i}" => cidr
  }

  tailscale_container_secret_name = "tailscale-oauth-client-secret"
  tailscale_service_id            = "svc:${var.tailscale_service_name}"
  tailscale_service_url           = var.enable_tailscale ? "https://${var.tailscale_service_name}.${var.tailscale_tailnet_dns_name}" : null

  network_cidrs = {
    vnet = var.vnet_address_space
    aca  = var.aca_subnet_prefix
    pe   = var.pe_subnet_prefix
  }

  network_starts = {
    for name, cidr in local.network_cidrs : name => sum([
      for index, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - index)
    ])
  }

  network_ends = {
    for name, cidr in local.network_cidrs : name => local.network_starts[name] + pow(2, 32 - tonumber(split("/", cidr)[1])) - 1
  }

  build_context = var.source_context_path != "" ? abspath(var.source_context_path) : "${var.hermes_source_repository}#${var.hermes_source_ref}"

  container_image = var.build_image_from_source ? "${azurerm_container_registry.hermes[0].login_server}/hermes-agent:${var.image_tag}" : var.public_image

  # Rendered gateway config, seeded into the container by an init container.
  config_yaml = templatefile("${path.module}/templates/config.yaml.tftpl", {
    base_url   = local.foundry_base_url
    model_name = var.model_name
  })

  # Non-secret environment for the gateway container.
  base_env = concat([
    { name = "HERMES_UID", value = "10000" },
    { name = "HERMES_GID", value = "10000" },
    { name = "HERMES_DASHBOARD", value = "1" },
    { name = "HERMES_DASHBOARD_HOST", value = var.enable_public_ingress ? "0.0.0.0" : "127.0.0.1" },
    { name = "HERMES_DASHBOARD_PORT", value = "9119" },
    { name = "HERMES_DASHBOARD_BASIC_AUTH_USERNAME", value = var.dashboard_username },
    { name = "AZURE_FOUNDRY_BASE_URL", value = local.foundry_base_url },
    # Makes DefaultAzureCredential select this user-assigned managed identity.
    { name = "AZURE_CLIENT_ID", value = azurerm_user_assigned_identity.hermes.client_id },
    ], [
    for k, v in var.gateway_env : { name = k, value = v }
  ])

  # Key Vault secret names, keyed by the environment variable exposed to Hermes.
  secret_names = merge(
    {
      HERMES_DASHBOARD_BASIC_AUTH_PASSWORD = "hermes-dashboard-password"
      HERMES_DASHBOARD_BASIC_AUTH_SECRET   = "hermes-dashboard-signing-secret"
    },
    var.gateway_secret_names,
  )

  normalized_secret_names = [
    for env_name in keys(local.secret_names) : lower(replace(env_name, "_", "-"))
  ]

  all_container_secret_names = concat(
    local.normalized_secret_names,
    var.enable_tailscale ? [local.tailscale_container_secret_name] : [],
  )

  reserved_env_names = toset([
    "HERMES_UID",
    "HERMES_GID",
    "HERMES_DASHBOARD",
    "HERMES_DASHBOARD_HOST",
    "HERMES_DASHBOARD_PORT",
    "HERMES_DASHBOARD_BASIC_AUTH_USERNAME",
    "AZURE_FOUNDRY_BASE_URL",
    "AZURE_CLIENT_ID",
  ])

  # Container App secret store: normalized secret name => Key Vault reference.
  container_secrets = merge(
    {
      for env_name, key_vault_name in local.secret_names : lower(replace(env_name, "_", "-")) => {
        key_vault_secret_id = "${azurerm_key_vault.hermes.vault_uri}secrets/${key_vault_name}"
      }
    },
    var.enable_tailscale ? {
      (local.tailscale_container_secret_name) = {
        key_vault_secret_id = "${azurerm_key_vault.hermes.vault_uri}secrets/${var.tailscale_oauth_client_secret_name}"
      }
    } : {},
  )

  # Env entries that reference the secrets above.
  secret_env = [
    for name, key_vault_name in local.secret_names : {
      name        = name
      secret_name = lower(replace(name, "_", "-"))
    }
  ]

  container_env = concat(
    [for e in local.base_env : { name = e.name, value = e.value, secret_name = null }],
    [for e in local.secret_env : { name = e.name, value = null, secret_name = e.secret_name }],
  )
}

# =============================================================================
# Resource group
# =============================================================================
resource "azurerm_resource_group" "hermes" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# =============================================================================
# Managed identity (keyless auth to Foundry + ACR pull)
# =============================================================================
resource "azurerm_user_assigned_identity" "hermes" {
  name                = "${var.prefix}-id"
  resource_group_name = azurerm_resource_group.hermes.name
  location            = azurerm_resource_group.hermes.location
  tags                = var.tags
}

# =============================================================================
# Dedicated Key Vault for Container App secrets
# =============================================================================
resource "azurerm_key_vault" "hermes" {
  name                          = local.key_vault_name
  resource_group_name           = azurerm_resource_group.hermes.name
  location                      = azurerm_resource_group.hermes.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90
  public_network_access_enabled = false
  tags                          = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_assignment" "key_vault_secrets_user" {
  scope                = azurerm_key_vault.hermes.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.hermes.principal_id
}

resource "azurerm_role_assignment" "key_vault_secrets_officer" {
  scope                = azurerm_key_vault.hermes.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# =============================================================================
# Microsoft Foundry (Azure AI Services) + model deployment
# =============================================================================
resource "azurerm_cognitive_account" "foundry" {
  name                          = local.foundry_name
  resource_group_name           = azurerm_resource_group.hermes.name
  location                      = azurerm_resource_group.hermes.location
  kind                          = "AIServices"
  sku_name                      = "S0"
  custom_subdomain_name         = local.foundry_name
  local_auth_enabled            = false
  public_network_access_enabled = true
  tags                          = var.tags
}

resource "azurerm_cognitive_deployment" "model" {
  name                 = var.model_name
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name     = var.model_sku_name
    capacity = var.model_capacity
  }
}

# Grant the container's managed identity keyless inference on the Foundry
# resource. DefaultAzureCredential (managed identity) mints a fresh token per
# request — no API keys are stored anywhere.
resource "azurerm_role_assignment" "foundry_access" {
  for_each = toset(var.foundry_role_definition_names)

  scope                = azurerm_cognitive_account.foundry.id
  role_definition_name = each.value
  principal_id         = azurerm_user_assigned_identity.hermes.principal_id
}

# =============================================================================
# Container registry (only when building the cloned repo from source)
# =============================================================================
resource "azurerm_container_registry" "hermes" {
  count = var.build_image_from_source ? 1 : 0

  name                = local.acr_name
  resource_group_name = azurerm_resource_group.hermes.name
  location            = azurerm_resource_group.hermes.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  count = var.build_image_from_source ? 1 : 0

  scope                = azurerm_container_registry.hermes[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.hermes.principal_id
}

# Build + push the repo's Dockerfile in the cloud via ACR Tasks. Requires the
# Azure CLI logged in with push rights. Re-runs when image_tag changes.
resource "null_resource" "image_build" {
  count = var.build_image_from_source ? 1 : 0

  triggers = {
    acr            = azurerm_container_registry.hermes[0].name
    image_tag      = var.image_tag
    source_context = local.build_context
    source_version = var.source_context_path != "" ? filemd5("${local.build_context}/Dockerfile") : var.hermes_source_ref
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      command -v az >/dev/null 2>&1 || {
        printf 'Azure CLI (az) is required to build the Hermes image.\n' >&2
        exit 127
      }
      az acr build \
        --registry "$ACR_NAME" \
        --image "hermes-agent:$IMAGE_TAG" \
        --file Dockerfile \
        "$BUILD_CONTEXT"
    EOT

    interpreter = ["/usr/bin/env", "bash", "-c"]

    environment = {
      ACR_NAME      = azurerm_container_registry.hermes[0].name
      IMAGE_TAG     = var.image_tag
      BUILD_CONTEXT = local.build_context
    }
  }
}

# =============================================================================
# Observability
# =============================================================================
resource "azurerm_log_analytics_workspace" "hermes" {
  name                = "${var.prefix}-law"
  resource_group_name = azurerm_resource_group.hermes.name
  location            = azurerm_resource_group.hermes.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# =============================================================================
# Networking (VNet-injected environment required for keyless NFS storage)
# =============================================================================
resource "azurerm_virtual_network" "hermes" {
  name                = "${var.prefix}-vnet"
  resource_group_name = azurerm_resource_group.hermes.name
  location            = azurerm_resource_group.hermes.location
  address_space       = [var.vnet_address_space]
  tags                = var.tags

  lifecycle {
    precondition {
      condition = (
        local.network_starts.aca >= local.network_starts.vnet &&
        local.network_ends.aca <= local.network_ends.vnet &&
        local.network_starts.pe >= local.network_starts.vnet &&
        local.network_ends.pe <= local.network_ends.vnet
      )
      error_message = "aca_subnet_prefix and pe_subnet_prefix must be fully contained in vnet_address_space."
    }

    precondition {
      condition     = local.network_ends.aca < local.network_starts.pe || local.network_ends.pe < local.network_starts.aca
      error_message = "aca_subnet_prefix and pe_subnet_prefix must not overlap."
    }
  }
}

resource "azurerm_subnet" "aca" {
  name                            = "aca-infra"
  resource_group_name             = azurerm_resource_group.hermes.name
  virtual_network_name            = azurerm_virtual_network.hermes.name
  address_prefixes                = [var.aca_subnet_prefix]
  service_endpoints               = ["Microsoft.Storage"]
  default_outbound_access_enabled = false

  delegation {
    name = "aca"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Dedicated subnet for the storage private endpoint (cannot live in the
# delegated Container Apps subnet).
resource "azurerm_subnet" "pe" {
  name                              = "pe"
  resource_group_name               = azurerm_resource_group.hermes.name
  virtual_network_name              = azurerm_virtual_network.hermes.name
  address_prefixes                  = [var.pe_subnet_prefix]
  private_endpoint_network_policies = "Disabled"
  default_outbound_access_enabled   = false
}

# =============================================================================
# Persistent state — Premium FileStorage NFS share mounted at /opt/data
# =============================================================================
# NFS is keyless (satisfies the org's no-shared-key policy). The account is
# firewalled to the Container Apps subnet; the share is created via the
# management plane (storage_account_id) so no data-plane key is needed.
resource "azurerm_storage_account" "hermes" {
  name                          = local.storage_name
  resource_group_name           = azurerm_resource_group.hermes.name
  location                      = azurerm_resource_group.hermes.location
  account_kind                  = "FileStorage"
  account_tier                  = "Premium"
  account_replication_type      = "LRS"
  https_traffic_only_enabled    = false # NFS 4.1 does not use TLS
  shared_access_key_enabled     = false # policy: keyless only
  public_network_access_enabled = false
  min_tls_version               = "TLS1_2"
  tags                          = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_share" "data" {
  name               = "hermes-data"
  storage_account_id = azurerm_storage_account.hermes.id
  enabled_protocol   = "NFS"
  quota              = var.state_share_quota_gb

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_account_network_rules" "hermes" {
  storage_account_id         = azurerm_storage_account.hermes.id
  default_action             = "Deny"
  virtual_network_subnet_ids = [azurerm_subnet.aca.id]
  bypass                     = ["AzureServices"]

  depends_on = [azurerm_storage_share.data]
}

# NFS Azure Files from Container Apps requires a private endpoint (service
# endpoints are not honored for the NFS data path). The private DNS zone makes
# <account>.file.core.windows.net resolve to the endpoint's private IP inside
# the VNet.
resource "azurerm_private_dns_zone" "file" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.hermes.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "file" {
  name                  = "hermes-file"
  resource_group_name   = azurerm_resource_group.hermes.name
  private_dns_zone_name = azurerm_private_dns_zone.file.name
  virtual_network_id    = azurerm_virtual_network.hermes.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "storage_file" {
  name                = "${var.prefix}-pe-file"
  resource_group_name = azurerm_resource_group.hermes.name
  location            = azurerm_resource_group.hermes.location
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "file"
    private_connection_resource_id = azurerm_storage_account.hermes.id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "file"
    private_dns_zone_ids = [azurerm_private_dns_zone.file.id]
  }

  tags = var.tags
}

# Key Vault public access is disabled by policy. This private DNS zone and
# endpoint let the VNet-integrated Container Apps environment resolve Key Vault
# references without traversing the public data-plane endpoint.
resource "azurerm_private_dns_zone" "vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.hermes.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "vault" {
  name                  = "hermes-vault"
  resource_group_name   = azurerm_resource_group.hermes.name
  private_dns_zone_name = azurerm_private_dns_zone.vault.name
  virtual_network_id    = azurerm_virtual_network.hermes.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "${var.prefix}-pe-vault"
  resource_group_name = azurerm_resource_group.hermes.name
  location            = azurerm_resource_group.hermes.location
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "vault"
    private_connection_resource_id = azurerm_key_vault.hermes.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "vault"
    private_dns_zone_ids = [azurerm_private_dns_zone.vault.id]
  }

  tags = var.tags
}

# =============================================================================
# Container Apps environment
# =============================================================================
resource "azurerm_container_app_environment" "hermes" {
  name                       = "${var.prefix}-cae"
  resource_group_name        = azurerm_resource_group.hermes.name
  location                   = azurerm_resource_group.hermes.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.hermes.id
  infrastructure_subnet_id   = azurerm_subnet.aca.id
  tags                       = var.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_container_app_environment_storage" "data" {
  name                         = "hermes-data"
  container_app_environment_id = azurerm_container_app_environment.hermes.id
  nfs_server_url               = "${azurerm_storage_account.hermes.name}.file.core.windows.net"
  share_name                   = "/${azurerm_storage_account.hermes.name}/${azurerm_storage_share.data.name}"
  access_mode                  = "ReadWrite"
}

# =============================================================================
# Hermes container app
# =============================================================================
resource "azurerm_container_app" "hermes" {
  name                         = "${var.prefix}-app"
  resource_group_name          = azurerm_resource_group.hermes.name
  container_app_environment_id = azurerm_container_app_environment.hermes.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  lifecycle {
    precondition {
      condition     = !var.enable_public_ingress || var.allow_unrestricted_ingress || length(var.allowed_ingress_ips) > 0
      error_message = "Set at least one allowed_ingress_ips CIDR, or explicitly set allow_unrestricted_ingress = true."
    }

    precondition {
      condition     = !var.enable_public_ingress || !var.allow_unrestricted_ingress || length(var.allowed_ingress_ips) == 0
      error_message = "allowed_ingress_ips must be empty when allow_unrestricted_ingress is true."
    }

    precondition {
      condition     = var.enable_public_ingress || (!var.allow_unrestricted_ingress && length(var.allowed_ingress_ips) == 0)
      error_message = "Public ingress settings must be disabled and allowed_ingress_ips empty when enable_public_ingress is false."
    }

    precondition {
      condition     = var.enable_public_ingress || var.enable_tailscale
      error_message = "Enable Tailscale before disabling Azure Container Apps ingress."
    }

    precondition {
      condition     = !var.enable_tailscale || var.tailscale_tailnet_dns_name != ""
      error_message = "tailscale_tailnet_dns_name is required when enable_tailscale is true."
    }

    precondition {
      condition     = var.container_memory == format("%gGi", var.container_cpu * 2)
      error_message = "container_memory must equal twice container_cpu for a supported Consumption workload combination."
    }

    precondition {
      condition     = length(distinct(local.all_container_secret_names)) == length(local.all_container_secret_names)
      error_message = "Secret environment names must remain unique after lowercasing and replacing underscores with hyphens."
    }

    precondition {
      condition     = length(setintersection(toset(keys(var.gateway_env)), local.reserved_env_names)) == 0
      error_message = "gateway_env cannot override a Terraform-managed environment variable."
    }

    precondition {
      condition     = length(setintersection(toset(keys(var.gateway_env)), toset(keys(local.secret_names)))) == 0
      error_message = "An environment variable cannot be declared in both gateway_env and gateway_secret_names."
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.hermes.id]
  }

  dynamic "registry" {
    for_each = var.build_image_from_source ? [1] : []
    content {
      server   = azurerm_container_registry.hermes[0].login_server
      identity = azurerm_user_assigned_identity.hermes.id
    }
  }

  dynamic "secret" {
    for_each = local.container_secrets
    content {
      name                = secret.key
      identity            = azurerm_user_assigned_identity.hermes.id
      key_vault_secret_id = secret.value.key_vault_secret_id
    }
  }

  template {
    # Stateful gateway on a shared SQLite DB: never run two replicas against
    # the same data dir, and don't scale to zero (drops messaging + app
    # connections).
    min_replicas = 1
    max_replicas = 1

    # Seed config.yaml into the persistent volume on first boot only, so a
    # restart never clobbers runtime state written by the gateway.
    init_container {
      name    = "seed-config"
      image   = local.container_image
      cpu     = 0.25
      memory  = "0.5Gi"
      command = ["/bin/sh", "-c"]
      args    = ["[ -f /opt/data/config.yaml ] || printf '%s' \"$HERMES_CONFIG_YAML\" > /opt/data/config.yaml"]

      env {
        name  = "HERMES_CONFIG_YAML"
        value = local.config_yaml
      }

      volume_mounts {
        name = "data"
        path = "/opt/data"
      }
    }

    container {
      name   = "hermes"
      image  = local.container_image
      cpu    = var.container_cpu
      memory = var.container_memory

      # Keep the image ENTRYPOINT (/init, s6-overlay). Only override CMD so the
      # container runs the supervised messaging gateway + web server.
      args = ["gateway", "run"]

      dynamic "env" {
        for_each = local.container_env
        content {
          name        = env.value.name
          value       = env.value.value
          secret_name = env.value.secret_name
        }
      }

      volume_mounts {
        name = "data"
        path = "/opt/data"
      }
    }

    dynamic "container" {
      for_each = var.enable_tailscale ? [1] : []
      content {
        name    = "tailscale"
        image   = var.tailscale_image
        cpu     = 0.25
        memory  = "0.5Gi"
        command = ["/bin/sh", "-c"]
        args = [<<-EOT
          set -eu

          /usr/local/bin/containerboot &
          child_pid=$!

          terminate() {
            kill -TERM "$child_pid" 2>/dev/null || true
            wait "$child_pid"
          }
          trap terminate TERM INT

          attempts=0
          until /usr/local/bin/tailscale status --json | grep -q '"BackendState": "Running"'; do
            if ! kill -0 "$child_pid" 2>/dev/null; then
              wait "$child_pid"
              exit $?
            fi

            attempts=$((attempts + 1))
            if [ "$attempts" -ge 60 ]; then
              echo "Tailscale did not reach Running state within 60 seconds" >&2
              kill -TERM "$child_pid" 2>/dev/null || true
              wait "$child_pid" || true
              exit 1
            fi
            sleep 1
          done

          /usr/local/bin/tailscale serve --service=${local.tailscale_service_id} --https=443 http://127.0.0.1:9119
          wait "$child_pid"
        EOT
        ]

        env {
          name        = "TS_AUTHKEY"
          secret_name = local.tailscale_container_secret_name
        }

        env {
          name  = "TS_EXTRA_ARGS"
          value = "--advertise-tags=${var.tailscale_tag}"
        }

        env {
          name  = "TS_HOSTNAME"
          value = "${var.prefix}-aca"
        }

        env {
          name  = "TS_USERSPACE"
          value = "true"
        }

        env {
          name  = "TS_KUBE_SECRET"
          value = ""
        }

        env {
          name  = "TS_ENABLE_HEALTH_CHECK"
          value = "true"
        }

        env {
          name  = "TS_LOCAL_ADDR_PORT"
          value = "0.0.0.0:9002"
        }

        startup_probe {
          transport               = "HTTP"
          port                    = 9002
          path                    = "/healthz"
          interval_seconds        = 5
          timeout                 = 2
          failure_count_threshold = 60
        }

        liveness_probe {
          transport               = "HTTP"
          port                    = 9002
          path                    = "/healthz"
          interval_seconds        = 30
          timeout                 = 5
          failure_count_threshold = 3
        }

      }
    }

    volume {
      name         = "data"
      storage_type = "NfsAzureFile"
      storage_name = azurerm_container_app_environment_storage.data.name
    }

  }

  dynamic "ingress" {
    for_each = var.enable_public_ingress ? [1] : []
    content {
      external_enabled = true
      target_port      = 9119
      transport        = "auto"

      dynamic "ip_security_restriction" {
        for_each = local.ingress_allow
        content {
          name             = ip_security_restriction.key
          action           = "Allow"
          ip_address_range = ip_security_restriction.value
        }
      }

      traffic_weight {
        latest_revision = true
        percentage      = 100
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.foundry_access,
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.key_vault_secrets_user,
    azurerm_private_endpoint.key_vault,
    azurerm_private_dns_zone_virtual_network_link.vault,
    azurerm_private_endpoint.storage_file,
    azurerm_private_dns_zone_virtual_network_link.file,
    null_resource.image_build,
  ]
}
