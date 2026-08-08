# Hermes Agent Azure Remediation Plan

## Status

**Complete**

This document tracks remediation of the Terraform and documentation review findings for the `hermes-agent-azure` repository. No Azure resource changes, Terraform state migration, `terraform plan`, or `terraform apply` may run until explicitly approved.

## Goals

- Protect Terraform state and secret material.
- Make public access intentional and accurately documented.
- Remove unsafe shell interpolation from the image build workflow.
- Make Hermes image deployments reproducible and observable by Terraform.
- Enforce keyless Microsoft Foundry authentication.
- Reject invalid input before Azure deployment.
- Simplify the Terraform dependency graph.
- Keep application source in `NousResearch/hermes-agent` and infrastructure in this repository.

## Constraints

- Preserve the currently deployed resources and existing local state.
- Never recreate or destroy resources to recover from migration errors.
- Source Azure subscription context from `ARM_SUBSCRIPTION_ID`; do not hardcode it.
- Run `terraform validate` before any `terraform plan`.
- Require explicit approval before `terraform plan`, `terraform apply`, Azure CLI changes, or other operations that can modify Azure resources.
- Keep unrelated repository changes out of remediation commits.

## Work Items

| ID | Priority | Status | Remediation | Acceptance criteria |
|---|---|---|---|---|
| REM-001 | High | Superseded by REM-012 | Configure a secure Azure Storage backend and document local-to-remote state migration. | Historical implementation retained in the change log; the active design now uses local state and manual backup snapshots. |
| REM-002 | High | Complete | Replace raw messaging secret values with Azure Key Vault references. | `gateway_secret_names` accepts only Key Vault secret names; Container Apps resolves versionless references with the user-assigned identity; required RBAC is explicit; dashboard credentials are populated out of band and never enter new Terraform state. |
| REM-003 | High | Complete | Make ingress access secure by default and align documentation. | A deployment cannot silently expose ingress to all IPv4 addresses; CIDRs are validated; README and examples describe the exact default and the explicit opt-in for public access. |
| REM-004 | High | Complete | Harden or remove the Terraform-driven ACR image build command. | No user-controlled value is directly interpolated into a shell command; paths with spaces work; Docker tags are validated; build failures are deterministic; unnecessary `null_resource` dependency behavior is removed. |
| REM-005 | Medium | Complete | Pin application source and images to immutable versions. | Public image supports a digest or immutable release tag; source builds use a release tag or commit SHA; changing the version creates a new Container Apps revision; floating `latest` and `main` are not production defaults. |
| REM-006 | Medium | Complete | Explicitly disable Foundry local authentication. | `local_auth_enabled = false` is declared and keyless Entra ID behavior is documented and validated. |
| REM-007 | Medium | Complete | Add Terraform input validation and cross-variable checks. | Invalid CIDRs, overlapping/out-of-range subnets, unsupported CPU-memory pairs, undersized NFS quota, invalid image tags, invalid environment names, and normalized secret-name collisions fail before Azure deployment. |
| REM-008 | Low | Complete | Remove redundant dependencies and unused declarations. | Implicit dependencies replace redundant `depends_on`; unused data, variables, locals, and outputs are removed; required ordering remains explicit only where no reference exists. |
| REM-009 | Medium | Complete | Update operational documentation. | README covers backend initialization, state migration, Key Vault setup, image updates, ingress exposure, validation, rollback, log inspection, and the requirement to run plan before apply without placing secrets on command lines. |
| REM-010 | Medium | Complete | Complete static and executable validation. | `terraform fmt -check`, `terraform init -backend=false`, `terraform validate`, `terraform providers lock`, `tflint`, and repository secret/state checks pass. A reviewed `terraform plan` is offered separately and only run with approval using `ARM_SUBSCRIPTION_ID`. |
| REM-011 | High | Complete | Add private Tailscale Service access with a staged public-ingress shutdown. | Terraform provides a digest-pinned userspace sidecar, ephemeral tagged identity, Key Vault-backed OAuth credential, stable Service output, health probes, and fail-safe ingress transition; README documents Tailscale administration, rollout, verification, and shutdown. |
| REM-012 | High | Complete | Keep Terraform state local and use Azure Blob only for manual disaster-recovery snapshots. | The explicit local backend uses the ignored root state file; existing checkouts reconfigure without migration; documentation covers single-operator limits, timestamped checksummed snapshots, private Blob upload, and recovery safeguards. |
| REM-013 | High | Complete | Keep Key Vault private-only while enabling Container Apps secret resolution and secure one-time seeding. | Terraform creates the private endpoint/DNS path and a disabled-by-default temporary job; the job seeds both required secrets through managed identity, then its password, write role, identity, and job are removed. |

## Execution Order

### Phase 1: Local safety and deterministic configuration

1. REM-006: enforce Foundry keyless authentication.
2. REM-003: secure ingress defaults and CIDR validation.
3. REM-005: pin image/source versions.
4. REM-004: harden the image build path.
5. REM-007 and REM-008: complete validation and dependency cleanup.
6. Run local formatting and validation after each focused edit.

### Phase 2: State and secret architecture

1. REM-001: add partial Azure backend configuration and migration documentation (later superseded by REM-012).
2. REM-002: add Key Vault references and identity RBAC.
3. REM-012: restore an explicit local backend and document manual Azure Blob backup snapshots.
4. Do not create Key Vault resources without explicit approval.

### Phase 3: Documentation and final verification

1. REM-009: align README and examples with the implemented behavior.
2. REM-010: run static checks and review the complete diff.
3. Request explicit approval before `terraform plan`.
4. Review the plan for replacement or destructive actions before any apply is considered.

## Validation Evidence

Record each command and result as work progresses.

| Check | Result |
|---|---|
| Baseline working tree | Clean before this plan was added |
| Existing `terraform fmt -check` | Passed during review |
| Existing `terraform validate` | Passed during review |
| State files ignored | Confirmed during review |
| `.terraform.lock.hcl` tracked | Confirmed during review |
| REM-001 `terraform fmt -check` | Passed |
| REM-001 `terraform init -backend=false` | Passed; no backend initialized or migrated |
| REM-001 `terraform validate` | Passed |
| REM-001 state/backend ignore checks | Passed; no state, backend config, or credentials tracked |
| REM-001 backend migration | Deferred; explicit approval and backend coordinates required |
| REM-002 `terraform fmt -check` | Passed |
| REM-002 `terraform init -backend=false` | Passed; no backend initialized or migrated |
| REM-002 `terraform validate` | Passed without warnings |
| REM-002 secret-value source scan | Passed; no managed secret values or `azurerm_key_vault_secret` resources in configuration |
| REM-002 Azure changes | Not run; dedicated vault bootstrap, secret population, plan, and apply require separate approval |
| REM-003 `terraform fmt -check` | Passed |
| REM-003 `terraform init -backend=false` | Passed |
| REM-003 `terraform validate` | Passed without warnings |
| REM-003 Azure changes | Not run; plan and apply require separate approval |
| REM-007 `terraform validate` | Passed after replacing unavailable `cidrcontains` with portable IPv4 range arithmetic |
| REM-008 dependency audit | Passed; both remaining explicit dependency blocks encode ordering that property references do not imply |
| REM-008 declaration audit | Passed; no unused data sources, variables, locals, or outputs found |
| REM-009 documentation review | Passed; operator flow now covers local checks, saved-plan review, immutable updates, verification, logs, and rollback boundaries |
| Final `terraform fmt -check` | Passed |
| Final `terraform init -backend=false` | Passed; no backend initialized or migrated |
| Final `terraform validate` | Passed without warnings |
| Final `terraform providers lock` | Passed for `darwin_arm64` and `linux_amd64`; lockfile updated with CI checksums |
| Final `git diff --check` and VS Code diagnostics | Passed |
| Final repository secret/state/floating-version checks | Passed; local state/tfvars/backend files ignored and none tracked |
| TFLint v0.64.0 with AzureRM ruleset v0.32.0 | Passed after adding `prevent_destroy` to Key Vault, storage account, and NFS share |
| `terraform plan` | Not run; approval and `ARM_SUBSCRIPTION_ID` required |
| REM-011 Terraform validation and TFLint | Passed; sidecar, probes, `EmptyDir`, Key Vault reference, conditional ingress, and outputs are valid with AzureRM v4.81.0 |
| REM-011 documentation review | Passed; Tailscale tag, OAuth, Service, policy, Key Vault, staged rollout, verification, and ingress shutdown are documented |
| REM-012 local backend reconfiguration | Passed; `terraform init -reconfigure`, `terraform state list`, and `terraform validate` use the existing local state without Azure Blob access |
| Key Vault bootstrap apply | Passed; vault and operator `Key Vault Secrets Officer` role exist, current Hermes revision remains healthy |
| Key Vault data-plane preflight | Blocked; public access is disabled, no private endpoint exists yet, and the operator workstation has no private route |
| REM-013 Terraform validation and TFLint | Passed; private endpoint, private DNS zone/link, and private-only vault configuration are valid |
| REM-013 targeted plan | Passed; `key-vault-private-endpoint.tfplan` contains 3 additions, 0 changes, and 0 destroys |
| REM-013 targeted apply | Passed; 3 resources added, 0 changed, and 0 destroyed; endpoint provisioning succeeded and its Key Vault connection is approved |
| REM-013 live network verification | Passed; `hermes-kv-hfbdww` remains private-only with no IP rules, and private DNS maps it to `10.10.2.5` |
| Post-REM-013 application verification | Passed; `hermes-app--393j8ai` remains healthy, provisioned, active, and receives 100% of traffic |
| Post-REM-013 state backup | Passed; `terraform.tfstate.20260806T211201Z.backup` and SHA-256 sidecar created locally and ignored by Git |
| REM-013 secret bootstrap execution | Passed; `hermes-secret-bootstrap-sw2am5p` completed with exit code 0 after both private Key Vault writes |
| REM-013 secret scrub and cleanup | Passed; temporary job secret removed, then job, vault write role, and identity destroyed; Azure and Terraform state contain no bootstrap resources |
| Post-bootstrap application verification | Passed; `hermes-app--393j8ai` remains healthy, provisioned, and receives 100% of traffic |
| Post-bootstrap state backup | Passed; `terraform.tfstate.20260806T214015Z.backup` and SHA-256 sidecar created locally and ignored by Git |
| Hermes runtime Key Vault role | Passed; `hermes-id` has vault-scoped `Key Vault Secrets User`; targeted apply added 1 resource with no changes or destroys |
| Final Hermes rollout | Passed; `hermes-app` updated in place to the digest-pinned image and private Key Vault references; no Azure resource was replaced or destroyed |
| Final application verification | Passed; `hermes-app--0000001` is healthy, provisioned, latest-ready, and receives 100% of traffic; the previous healthy revision remains active at 0% for rollback |
| Final endpoint and security verification | Passed; HTTPS returned 200, ingress remains restricted to `139.94.119.28/32`, and Key Vault remains RBAC-enabled, deny-by-default, private-only, and connected through an approved private endpoint |
| Final authenticated UI verification | Passed; operator confirmed the Hermes UI is reachable and login succeeds with the Key Vault-backed dashboard credentials |
| Final Terraform convergence | Passed; a fresh full `terraform plan -detailed-exitcode` reported no changes |
| Final state backup | Passed; `terraform.tfstate.20260806T214559Z.backup` and SHA-256 sidecar were created with private permissions, checksum-verified, and ignored by Git |
| Tailscale credential bootstrap | Passed; the OAuth client secret was written to private Key Vault through the temporary VNet-hosted job without entering Terraform state or command arguments |
| Tailscale credential cleanup | Passed; the job secret was scrubbed and the temporary job, write role, and identity were destroyed; no secret-bootstrap resources remain in Azure or Terraform state |
| Tailscale ACA runtime correction | Passed; `TS_KUBE_SECRET` explicitly disables Kubernetes state inference, and the sidecar waits for `BackendState: Running` before configuring the Service with `tailscale serve` |
| Tailscale durable revision health | Passed; `hermes-app--0000004` is the only active revision, is healthy and provisioned at 100% traffic, and both `hermes` and `tailscale` are ready/running with zero restarts |
| Tailscale Service ownership | Passed; the admin console reports the new host Connected, and the macOS client routes the Service VIP to `hermes-aca-1.taile1e16.ts.net` after the prior probe revision retired |
| Tailscale private HTTPS verification | Passed; with only revision `0000004` active, `https://hermes.taile1e16.ts.net` returned HTTP/2 `302` to `/login?next=%2F` from Hermes/Uvicorn |
| Tailscale authenticated browser acceptance | Passed; operator confirmed the private Service URL loads and authenticated login succeeds while connected to Tailscale |
| Tailscale native-client acceptance | Pending operator confirmation; restricted Azure ingress remains enabled as the recovery path until the macOS/iOS WebSocket check passes |

## Future Decisions

- Identity or operator group that may upload private state-backup blobs.
- Durable operator path for future private Key Vault secret rotation, such as a
  point-to-site VPN or approved jump host. The temporary job remains available
  for reviewed one-time rotations without public vault access.

## Change Log

- 2026-08-06: Initial remediation tracker created from the Terraform and documentation review.
- 2026-08-06: REM-001 started; partial Entra-authenticated Azure Storage backend and migration guidance added. No state migration performed.
- 2026-08-06: REM-001 completed locally. Provider and backend now share `ARM_SUBSCRIPTION_ID`; formatting, backend-disabled initialization, validation, and state hygiene checks passed.
- 2026-08-06: REM-012 superseded REM-001 by operator decision. Terraform now uses the existing local state as authoritative; Azure Blob Storage is documented only as a manual, timestamped disaster-recovery backup destination. No state upload, plan, apply, or Azure mutation was run.
- 2026-08-06: REM-002 started with a dedicated RBAC-enabled Key Vault design. Secret values are populated out of band and are not managed by Terraform.
- 2026-08-06: REM-002 completed locally. Dedicated vault, least-privilege RBAC, versionless Container App references, staged bootstrap guidance, and legacy credential-rotation guidance added; no Azure changes executed.
- 2026-08-06: REM-003 started; ingress now requires valid IPv4 allow rules or an explicit unrestricted-access opt-in.
- 2026-08-06: REM-003 completed locally; CIDR validation, fail-closed preconditions, explicit unrestricted opt-in, and aligned documentation passed validation.
- 2026-08-06: REM-004 started; hardening the ACR Tasks local provisioner and removing redundant dependencies.
- 2026-08-06: REM-004 completed locally; dynamic build inputs now pass through a quoted environment, Bash strict mode and CLI checks make failures deterministic, tags are validated, and redundant ordering was removed.
- 2026-08-06: REM-005 started; verified Hermes v2026.8.3 in Git and its Docker manifest digest before pinning defaults.
- 2026-08-06: REM-005 completed locally; public pulls require a SHA-256 digest, source builds default to an immutable release, and floating production inputs are rejected.
- 2026-08-06: REM-006 started; Foundry local authentication is being disabled explicitly to enforce the existing managed-identity path.
- 2026-08-06: REM-006 completed locally; Foundry local authentication is explicitly disabled and the managed-identity-only contract is documented.
- 2026-08-06: REM-007 started; adding hard validation for compute, storage, networking, environment, and secret-name contracts.
- 2026-08-06: REM-007 completed locally; invalid compute, quota, CIDR, subnet, environment, and normalized secret combinations now fail validation or resource preconditions.
- 2026-08-06: REM-008 completed locally; all remaining explicit dependencies are required for control-plane or runtime readiness, and no dead declarations were found.
- 2026-08-06: REM-009 completed locally; operational documentation now covers pre-plan checks, saved-plan review, immutable updates, health/log verification, and Terraform-controlled rollback.
- 2026-08-06: REM-010 local checks passed except `tflint`, which is not installed. No plan, backend migration, Azure CLI mutation, or apply was run.
- 2026-08-06: REM-010 completed locally. TFLint v0.64.0 and AzureRM ruleset v0.32.0 passed after protecting durable resources from accidental destruction; all remediation items are complete.
- 2026-08-06: REM-011 completed locally. Added a digest-pinned Tailscale userspace sidecar with an ephemeral tagged identity and stable `svc:hermes` endpoint, plus complete Tailscale admin and staged migration documentation. No plan, apply, Tailscale mutation, or Azure mutation was run.
- 2026-08-06: Key Vault bootstrap applied successfully and a checksummed local state snapshot was created. Live verification found the vault private-only with no private endpoint, so the complete application plan was declared stale and not applied.
- 2026-08-06: REM-013 added a Key Vault private endpoint and private DNS path. Static validation passed; deployment remains blocked until an approved operator network path can seed and verify the required secrets.
- 2026-08-06: A temporary `139.94.119.28/32` Key Vault exception was attempted with operator approval. Azure policy restored disabled public access before data-plane access succeeded; no secret was created, and verification confirmed the temporary IP rule was removed.
- 2026-08-06: Applied and verified REM-013's targeted private-connectivity plan: the private DNS zone, VNet link, and approved Key Vault private endpoint were added without changing or destroying existing resources. The current Hermes revision remained healthy. Required secrets are still absent and block the complete app rollout.
- 2026-08-06: REM-013 completed. A temporary VNet-hosted Container Apps Job used a dedicated managed identity to create both required secrets through the private endpoint. Execution completed successfully, the temporary password was scrubbed, all three bootstrap resources and their privilege were destroyed, and the existing Hermes revision remained healthy.
- 2026-08-06: Granted the existing Hermes runtime identity vault-scoped `Key Vault Secrets User`, then applied the reviewed final rollout. Revision `hermes-app--0000001` is healthy and latest-ready at 100% traffic with the digest-pinned image and private Key Vault references; Terraform converges with no changes, and the final local state snapshot is checksum-verified.
- 2026-08-06: Final runtime acceptance completed. The operator confirmed the Hermes UI is reachable and authenticated login succeeds with the Key Vault-backed dashboard credentials.
- 2026-08-06: Tailscale credential bootstrap and cleanup completed without exposing the OAuth secret. The first ACA sidecar rollout required an explicit non-Kubernetes state setting and a bounded startup wrapper so Service configuration occurs only after the Tailscale backend reaches `Running`.
- 2026-08-06: Durable Tailscale Service startup was proven on revision `hermes-app--0000004`. After the old manual-probe revision retired, the Service VIP moved to `hermes-aca-1` and the private URL continued returning Hermes' login redirect. Restricted Azure ingress remains enabled pending operator browser and native-client acceptance.
- 2026-08-06: Authenticated browser acceptance passed through the private Tailscale Service. Native-client WebSocket acceptance remains pending, so the restricted Azure recovery endpoint was deliberately retained.
