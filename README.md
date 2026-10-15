# pve-platform-iac

**English** · [Español](README.es.md)

> **Beta (v0.1.0).** The design, the security model and the documentation are complete and
> checked in CI, but the platform has **not yet been run against a real Proxmox cluster**. See
> [Status](#status).

**Self-service virtual machines for in-house teams at companies and SMBs running Proxmox VE**,
with a strict GitOps model. Teams ask for a VM or a k3s cluster by adding a small YAML file to
`requests/`, an admin reviews the pull request, and only the pipeline applies it. Terraform
([`bpg/proxmox`](https://github.com/bpg/terraform-provider-proxmox)) creates the machines and
Ansible configures them (per-project accounts, Docker, k3s, monitoring).

```
fork → requests/x.yaml → PR ──► pr-validate (no secrets) + pr-plan (read-only, posted on the PR)
                                         │
                            admin reviews and merges
                                         ▼
main ──► deploy: plan → apply that exact plan → host keys → Ansible
nightly ──► drift: fails and opens an issue if Proxmox ≠ main (never auto-fixes)
```

## Why

- **Teams get VMs without tickets, admins keep control.** Every change is a reviewed PR, with its
  plan posted on it, and an audit trail in git.
- **A closed catalog of flavors** (sizes and profiles) keeps capacity predictable. Each
  installation adds its own, such as a database VM or a CI runner
  ([docs/extender.md](docs/extender.md)).
- **Per-project isolation**: each project gets its own Proxmox pool and VMID/IP ranges, and only
  its members get an account on its VMs, with their GitHub SSH keys.
- **Hardened by default**: unreviewed code never sees secrets, plans are encrypted and applied
  byte-for-byte, TLS and SSH host keys are verified, base images are pinned and GPG-checked, and
  Proxmox tokens have no ACL on `/`. See [docs/seguridad.md](docs/seguridad.md).

## Requirements

| Component | Required | Notes |
|---|---|---|
| Proxmox VE 8.4+ / 9.x | yes | 1 to N nodes. Install it with [platform-proxmox](https://github.com/teo-devops/platform-proxmox) |
| GitHub | yes | Organization (recommended) or personal account with a public repo ([D-01](docs/diseno.md#decisiones)) |
| A small Docker host on your network | yes | Ephemeral self-hosted runners (`runner/`) |
| HCP Terraform (Free) | yes | State and locking only; runs execute on your runners |
| Cloudflare Zero Trust (Free) | optional | VPN for developers to reach their VMs |
| Proxmox Backup Server + S3 (e.g. SeaweedFS) | optional | Encrypted, deduplicated backups |

## Getting started

```sh
gh repo create <owner>/pve-platform-iac --private --template teo-devops/pve-platform-iac --clone
cd pve-platform-iac
make init OWNER=@<owner>/<admins-team>   # your config from examples/, your CODEOWNERS
make check
```

Then follow [docs/bootstrap.md](docs/bootstrap.md) (in Spanish): Proxmox, GitHub rulesets and
environments, HCP, runners, VPN and backups. `make preflight` tells you what is still missing.

| You are… | Read |
|---|---|
| A developer asking for VMs | [docs/inicio-rapido.md](docs/inicio-rapido.md), [CONTRIBUTING.md](CONTRIBUTING.md) |
| The admin of an installation | [docs/bootstrap.md](docs/bootstrap.md), [docs/operador.md](docs/operador.md), [docs/extender.md](docs/extender.md) |
| Reviewing the design | [docs/diseno.md](docs/diseno.md), [docs/seguridad.md](docs/seguridad.md) |

The documentation is in Spanish ([docs/README.md](docs/README.md)). Run `make` to list the
commands.

## Extras

[`dataspace-kind`](docs/dataspace.md) is an optional, example profile that deploys Eclipse EDC
dataspace MVPs on kind. It depends on private images, so outside its reference installation it
serves as a template for writing your own profile.

## Status

As of **15 Oct 2026**:

- **Checked in CI:** `terraform fmt`/`validate`, tflint, ansible-lint and syntax checks,
  actionlint, JSON Schema for requests, `iac check`, internal doc links and the catalog table.
- **Not yet run against real infrastructure:** plan and apply on Proxmox, the exact privileges
  of the `IaCApply` role, the workflows on self-hosted runners, backups and the VPN.
- **No unit tests yet** for `scripts/iac` and no `terraform test`. That comes before 1.0.

History: [CHANGELOG.md](CHANGELOG.md). Security reports: [SECURITY.md](SECURITY.md).

## License

[Apache-2.0](LICENSE).
