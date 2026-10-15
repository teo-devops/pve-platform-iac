# Runbook: secreto comprometido

**Síntoma:** un secreto ha aparecido donde no debía (un log, un chat, un portátil robado), alguien
que no debía ha tenido acceso, o hay algo inexplicable (un plan alterado, VMs que nadie pidió).
**Quién:** un admin. Actúa primero y analiza después.
**Resultado esperado:** la credencial vieja ya no sirve y sabes qué se hizo con ella.

## 1. Cortar (en este orden)

| Secreto | Revocar ya |
|---|---|
| `PM_APPLY_TOKEN` | `pveum user token remove iac@pve apply` en un nodo |
| `PM_PLAN_TOKEN` | `pveum user token remove iac@pve plan` |
| `TF_API_TOKEN` | HCP → owners → Regenerate token |
| `ANSIBLE_SSH_KEY` | PR quitando `service.ci.ssh_key` + deploy, o a mano: quítala de `~ops/.ssh/authorized_keys` en cada VM |
| `GHCR_READ_TOKEN` | GitHub → Settings → Developer settings → Tokens → Delete |
| `DATASPACE_MVP_DEPLOY_KEY` | `gh repo deploy-key delete <id> -R teo-devops/dataspace-mvp` |
| `PLAN_ENC_KEY` | `openssl rand -base64 48 \| gh secret set PLAN_ENC_KEY --env production` |
| PAT de runners | Revócalo en GitHub y para los supervisores |
| Cuenta de GitHub de un admin | Sácala de `infra-admins` y de la organización |

Si sospechas del pipeline (plan alterado, workflow cambiado): desactiva los workflows mientras
investigas (`gh workflow disable deploy.yml -R <ORG>/pve-platform-iac`, y lo mismo con drift y pr-plan).

## 2. Investigar

- Proxmox: Datacenter → Tasks y `/var/log/pve/tasks/`: qué hizo el token y desde qué IP.
- GitHub: Organization → Audit log (secretos leídos, workflows cambiados, miembros añadidos).
- HCP: workspace → States (versiones del estado y quién las escribió).
- `git log -p .github/` desde la fecha sospechosa.
- `drift` a mano: ¿hay cambios en Proxmox que no vienen de Git?

## 3. Reponer

Crea las credenciales nuevas como en [credenciales.md](../credenciales.md), vuelve a activar los
workflows y lanza deploy y drift a mano. Apunta el incidente en el registro de break-glass.
