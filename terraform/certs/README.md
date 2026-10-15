# terraform/certs

Aquí va `pve-root-ca.pem`, la CA del cluster Proxmox (pública, no es un secreto). El provider la usa
para verificar TLS (`insecure = false`) a través de `scripts/ca-bundle.sh`.

Cómo obtenerla y comprobarla: [docs/bootstrap.md §3](../../docs/bootstrap.md#3-ca-del-cluster-proxmox-tls-verificado).
Mientras falte, el plan falla a propósito y `make preflight` lo señala.
