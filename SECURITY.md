# Security policy

## Supported versions

This project is in **beta** (`v0.x`). Only the latest release and `main` receive fixes.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private vulnerability reporting:
**Security → Report a vulnerability** on this repository. You will get an answer within a few
days.

In scope:
- the pipeline (`.github/workflows/`): anything that lets a pull request run code or read
  secrets on self-hosted runners, or apply changes without review;
- `runner/`: container escape paths or leaking the runner PAT;
- Terraform/Ansible code that weakens a documented control (`R-nn` in
  [docs/seguridad.md](docs/seguridad.md)) or grants more Proxmox privileges than documented;
- secrets ending up in logs, artifacts, the Terraform state or the VMs.

Out of scope: risks already listed as accepted (`A-n` in [docs/seguridad.md](docs/seguridad.md))
and issues of a specific installation's configuration.
