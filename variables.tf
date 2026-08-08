variable "prefix" {
  type        = string
  description = "Short lowercase prefix for resource names (letters/digits)."
  default     = "hermes"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,11}$", var.prefix))
    error_message = "prefix must be 2-12 chars, lowercase letters/digits, starting with a letter."
  }
}

variable "location" {
  type        = string
  description = "Azure region. Must offer the chosen Foundry model."
  default     = "eastus2"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to create."
  default     = "rg-hermes"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default = {
    application = "hermes-agent"
    managed_by  = "terraform"
  }
}

# =============================================================================
# Microsoft Foundry (Azure AI Services) model
# =============================================================================
variable "model_name" {
  type        = string
  description = "Model/deployment name. Hermes auto-routes gpt-5.x to the Responses API by name."
  default     = "gpt-5.5"
}

variable "model_version" {
  type        = string
  description = "Model version for the deployment."
  default     = "2026-04-24"
}

variable "model_sku_name" {
  type        = string
  description = "Deployment SKU (GlobalStandard, Standard, DataZoneStandard, ...)."
  default     = "GlobalStandard"
}

variable "model_capacity" {
  type        = number
  description = "Deployment capacity in thousands of tokens-per-minute."
  default     = 50
}

variable "foundry_role_definition_names" {
  type        = list(string)
  description = <<-EOT
    Built-in RBAC roles granted to the container's managed identity on the
    Foundry resource for keyless inference. "Cognitive Services OpenAI User"
    covers gpt-5.x inference on the /openai/v1 endpoint. Add "Azure AI User"
    only if that (newer) role exists in your tenant.
  EOT
  default     = ["Cognitive Services OpenAI User"]
}

# =============================================================================
# Container image
# =============================================================================
variable "build_image_from_source" {
  type        = bool
  description = <<-EOT
    true  = build the cloned repo's Dockerfile with `az acr build` into a
            private ACR (self-contained, but the first build takes 20-40 min).
    false = pull the prebuilt public image (fast). Default.
  EOT
  default     = false
}

variable "public_image" {
  type        = string
  description = "Digest-pinned prebuilt image used when build_image_from_source = false."
  default     = "docker.io/nousresearch/hermes-agent@sha256:16788311e2fa3035456bdc1bafb8ec2b1777db64ebf020af9bb7eb73c3712c9e"

  validation {
    condition     = can(regex("^[a-z0-9.-]+(?::[0-9]+)?/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$", var.public_image))
    error_message = "public_image must be an OCI image reference pinned to a sha256 digest."
  }
}

variable "image_tag" {
  type        = string
  description = "Tag used when building from source. Bump to force a rebuild."
  default     = "v2026.8.3"

  validation {
    condition = (
      can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.image_tag)) &&
      lower(var.image_tag) != "latest"
    )
    error_message = "image_tag must be a valid, non-latest Docker tag of at most 128 characters."
  }
}

variable "source_context_path" {
  type        = string
  description = "Optional local Hermes repo root to use as the Docker build context instead of the remote repository."
  default     = ""
}

variable "hermes_source_repository" {
  type        = string
  description = "Hermes Agent Git repository used by ACR Tasks when building from source."
  default     = "https://github.com/NousResearch/hermes-agent.git"

  validation {
    condition     = can(regex("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\\.git)?$", var.hermes_source_repository))
    error_message = "hermes_source_repository must be an HTTPS GitHub repository URL."
  }
}

variable "hermes_source_ref" {
  type        = string
  description = "Immutable release tag or full commit SHA of Hermes Agent to build."
  default     = "v2026.8.3"

  validation {
    condition = (
      can(regex("^(?:v[0-9][A-Za-z0-9._-]{0,126}|[a-f0-9]{40})$", var.hermes_source_ref)) &&
      !contains(["main", "master", "latest"], lower(var.hermes_source_ref))
    )
    error_message = "hermes_source_ref must be an immutable v-prefixed release tag or full 40-character commit SHA."
  }
}

# =============================================================================
# Container App runtime
# =============================================================================
variable "container_cpu" {
  type        = number
  description = "vCPU for the Hermes container (Consumption allows up to 4)."
  default     = 2.0

  validation {
    condition     = contains([for quarter in range(1, 17) : quarter / 4], var.container_cpu)
    error_message = "container_cpu must be between 0.25 and 4 vCPU in 0.25-vCPU increments."
  }
}

variable "container_memory" {
  type        = string
  description = "Memory for the Hermes container (e.g. 4Gi)."
  default     = "4Gi"

  validation {
    condition     = can(regex("^(?:0\\.5|[1-7](?:\\.5)?|8)Gi$", var.container_memory))
    error_message = "container_memory must be between 0.5Gi and 8Gi in 0.5-Gi increments."
  }
}

variable "state_share_quota_gb" {
  type        = number
  description = "NFS Azure Files share size (GiB) for /opt/data. Premium FileStorage minimum is 100."
  default     = 100

  validation {
    condition     = var.state_share_quota_gb >= 100 && var.state_share_quota_gb <= 102400 && floor(var.state_share_quota_gb) == var.state_share_quota_gb
    error_message = "state_share_quota_gb must be a whole number from 100 through 102400 GiB."
  }
}

variable "allowed_ingress_ips" {
  type        = list(string)
  description = "IPv4 CIDRs allowed to reach app ingress. Required unless unrestricted ingress is explicitly enabled."
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.allowed_ingress_ips :
      can(cidrnetmask(cidr)) && can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}/(?:[0-9]|[12][0-9]|3[0-2])$", cidr))
    ])
    error_message = "allowed_ingress_ips must contain valid IPv4 CIDRs with prefix lengths from 0 to 32."
  }
}

variable "allow_unrestricted_ingress" {
  type        = bool
  description = "Explicitly allow public ingress from every IPv4 address. Keep false for normal deployments."
  default     = false
}

variable "enable_public_ingress" {
  type        = bool
  description = "Keep Azure Container Apps ingress enabled. Disable only after Tailscale access is verified."
  default     = true
}

variable "enable_tailscale" {
  type        = bool
  description = "Run a Tailscale userspace sidecar and advertise Hermes as a Tailscale Service."
  default     = false
}

variable "tailscale_image" {
  type        = string
  description = "Digest-pinned official Tailscale container image."
  default     = "docker.io/tailscale/tailscale@sha256:cdf5612ded5be1344f1a704b8c5e53496db97376bb533e5e15f141e48bf60cc0"

  validation {
    condition     = can(regex("^docker\\.io/tailscale/tailscale@sha256:[a-f0-9]{64}$", var.tailscale_image))
    error_message = "tailscale_image must be the official Tailscale image pinned to a sha256 digest."
  }
}

variable "tailscale_service_name" {
  type        = string
  description = "Tailscale Service name, without the svc: prefix."
  default     = "hermes"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.tailscale_service_name))
    error_message = "tailscale_service_name must start with a lowercase letter and contain only lowercase letters, digits, and hyphens."
  }
}

variable "tailscale_tailnet_dns_name" {
  type        = string
  description = "Tailnet MagicDNS suffix, such as example.ts.net. Required when Tailscale is enabled."
  default     = ""

  validation {
    condition     = var.tailscale_tailnet_dns_name == "" || can(regex("^[a-z0-9][a-z0-9-]*\\.ts\\.net$", var.tailscale_tailnet_dns_name))
    error_message = "tailscale_tailnet_dns_name must be empty or a valid lowercase *.ts.net MagicDNS suffix."
  }
}

variable "tailscale_tag" {
  type        = string
  description = "Tag advertised by the ephemeral Tailscale service host."
  default     = "tag:hermes"

  validation {
    condition     = can(regex("^tag:[a-z][a-z0-9-]{0,62}$", var.tailscale_tag))
    error_message = "tailscale_tag must use the tag:name form with lowercase letters, digits, and hyphens."
  }
}

variable "tailscale_oauth_client_secret_name" {
  type        = string
  description = "Key Vault secret containing a Tailscale OAuth client secret authorized for tailscale_tag."
  default     = "tailscale-oauth-client-secret"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]{1,127}$", var.tailscale_oauth_client_secret_name))
    error_message = "tailscale_oauth_client_secret_name must be a valid Azure Key Vault secret name."
  }
}

variable "vnet_address_space" {
  type        = string
  description = "Address space for the Container Apps VNet."
  default     = "10.10.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vnet_address_space)) && can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}/(?:[0-9]|[12][0-9]|3[0-2])$", var.vnet_address_space))
    error_message = "vnet_address_space must be a valid IPv4 CIDR."
  }
}

variable "aca_subnet_prefix" {
  type        = string
  description = "Subnet CIDR for the Container Apps environment (/23 recommended)."
  default     = "10.10.0.0/23"

  validation {
    condition = (
      can(cidrnetmask(var.aca_subnet_prefix)) &&
      can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}/(?:[0-9]|1[0-9]|2[0-3])$", var.aca_subnet_prefix))
    )
    error_message = "aca_subnet_prefix must be a valid IPv4 CIDR with a /23 or larger address range."
  }
}

variable "pe_subnet_prefix" {
  type        = string
  description = "Subnet CIDR for the storage private endpoint."
  default     = "10.10.2.0/24"

  validation {
    condition = (
      can(cidrnetmask(var.pe_subnet_prefix)) &&
      can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}/(?:[0-9]|[12][0-9])$", var.pe_subnet_prefix))
    )
    error_message = "pe_subnet_prefix must be a valid IPv4 CIDR with a /29 or larger address range."
  }
}

# =============================================================================
# App / dashboard access (the connection info your macOS & iOS apps use)
# =============================================================================
variable "dashboard_username" {
  type        = string
  description = "Basic-auth username for the web/app gateway on port 9119."
  default     = "hermes"
}

variable "enable_secret_bootstrap" {
  type        = bool
  description = "Create the temporary VNet-hosted job used to seed required Key Vault secrets. Disable and destroy it immediately after use."
  default     = false
}

# =============================================================================
# Extra gateway environment (messaging platform config, etc.)
# =============================================================================
variable "gateway_env" {
  type        = map(string)
  description = <<-EOT
    Non-secret env vars passed to the gateway container, e.g.
    { TELEGRAM_ALLOWED_USERS = "123,456" }.
  EOT
  default     = {}

  validation {
    condition     = alltrue([for name in keys(var.gateway_env) : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", name))])
    error_message = "gateway_env keys must be valid environment variable names."
  }
}

variable "gateway_secret_names" {
  type        = map(string)
  description = <<-EOT
    Secret environment variables mapped to secret names in the dedicated Key
    Vault. Values are names, never secret material. Example:
    { TELEGRAM_BOT_TOKEN = "telegram-bot-token" }.
  EOT
  default     = {}

  validation {
    condition     = alltrue([for name in keys(var.gateway_secret_names) : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", name))])
    error_message = "gateway_secret_names keys must be valid environment variable names."
  }

  validation {
    condition     = alltrue([for secret_name in values(var.gateway_secret_names) : can(regex("^[A-Za-z0-9-]{1,127}$", secret_name))])
    error_message = "gateway_secret_names values must be valid Azure Key Vault secret names."
  }

  validation {
    condition = length(distinct([
      for name in keys(var.gateway_secret_names) : lower(replace(name, "_", "-"))
    ])) == length(var.gateway_secret_names)
    error_message = "gateway_secret_names keys must remain unique after lowercasing and replacing underscores with hyphens."
  }
}
