# Credenciales

**Para quién:** el admin. Cada secreto y cada variable: qué es, dónde vive, quién lo ve, qué alcance
tiene y cómo rotarlo. Si alguno se filtra: [runbooks/token-comprometido.md](runbooks/token-comprometido.md).

**Regla general:** los devs y los freelancers **no tienen ninguna credencial de infraestructura**.
Piden por PR, y el pipeline aplica con secretos que solo ven los jobs de `main`.

## Resumen

| Secreto / variable | Dónde vive | Lo usan | Alcance |
|---|---|---|---|
| `PM_APPLY_TOKEN` | env `production` | deploy (plan, apply), drift | Token `iac@pve!apply`: rol `IaCApply` en pools, storages, zona y nodos. Nada en `/` |
| `PM_PLAN_TOKEN` | env `plan` | pr-plan | Token `iac@pve!plan`: `PVEAuditor` en las mismas rutas. Solo lectura |
| `TF_API_TOKEN` | envs `production` y `plan` | todos los jobs con Terraform | Token de equipo owners de la organización de HCP, que solo contiene el workspace `homelab` |
| `ANSIBLE_SSH_KEY` | env `production` | deploy (configure) | Privada de la cuenta de servicio `ci`: entra como `ops` en todas las VMs |
| `PLAN_ENC_KEY` | env `production` | deploy (plan, apply) | Clave simétrica que cifra el plan entre jobs |
| `GHCR_READ_TOKEN` | env `production` | deploy (configure, perfil dataspace-kind) | PAT clásico con **solo** `read:packages` |
| `DATASPACE_MVP_DEPLOY_KEY` | env `production` | deploy (configure, perfil dataspace-kind) | Deploy key de **solo lectura** de `teo-devops/dataspace-mvp` |
| `TF_CLOUD_ORGANIZATION` | variable del repo | todos | Nombre de la organización de HCP (no es secreto) |
| `GHCR_USER` | variable del repo | configure | Usuario dueño de `GHCR_READ_TOKEN` (no es secreto) |
| PAT de runners | `/etc/homelab-runner/env` en el host de runners | `runner/supervisor.sh` | Fine-grained, organización, solo «Self-hosted runners: read and write» |
| Token del túnel de Cloudflare | servicio `cloudflared` en el LXC del conector | `cloudflared` | Permite levantar un conector de **ese** túnel ([abajo](#túnel-de-cloudflare)) |
| Secret de la OAuth App de GitHub | Zero Trust → Login methods | Cloudflare | Login de las personas en WARP; no da acceso a GitHub |

Los environments `production` y `plan` solo despliegan desde `main` ([bootstrap.md §5](bootstrap.md#5-environments-y-secretos)),
así que ningún job de una rama o de un fork recibe estos secretos.

## Token de escritura `iac@pve!apply`

- **Creación:** `make proxmox-acl` ([bootstrap.md §8](bootstrap.md#8-proxmox-tokens-pools-y-acl)).
  Token con privsep: sus permisos son solo sus ACL, no los del usuario `iac@pve`.
- **Rol `IaCApply`** (`APPLY_PRIVS` en `scripts/iac`), privilegio a privilegio:

  | Privilegio | Para qué |
  |---|---|
  | `VM.Allocate`, `VM.Clone`, `VM.Audit` | Crear, borrar y leer VMs (en sus pools) |
  | `VM.Config.*` (CDROM, CPU, Cloudinit, Disk, HWType, Memory, Network, Options) | Configurar la VM; el CDROM es la unidad de cloud-init |
  | `VM.GuestAgent.Audit` | Leer el agente (el provider lo consulta) |
  | `VM.PowerMgmt` | Arrancar y parar la VM |
  | `Pool.Audit` | Ver los pools al asignar la VM |
  | `Datastore.AllocateSpace`, `Datastore.Audit` | Discos de las VMs |
  | `Datastore.AllocateTemplate` | Descargar la imagen base al storage de imágenes |
  | `Sys.AccessNetwork` (en el nodo) | Que el nodo descargue la imagen. Sustituye a `Sys.Modify` en `/` |
  | `SDN.Use` | Conectar la VM al bridge |
  | `Sys.Audit` | Leer el estado del nodo |
- **Rotar:**

  ```sh
  ssh root@<nodo> pveum user token remove iac@pve apply
  make proxmox-acl > acl.sh && scp acl.sh root@<nodo>: && ssh root@<nodo> bash acl.sh   # crea el token nuevo
  gh secret set PM_APPLY_TOKEN -R <ORG>/homelab-iac --env production
  ```
  Después, lanza `drift` a mano: tiene que funcionar con el token nuevo.

## Token de lectura `iac@pve!plan`

Igual que el anterior, con `PVEAuditor`. Lo ven los jobs de `pr-plan` (environment `plan`). Lo peor
que permite es **leer** el inventario de los pools del repo. Para rotarlo, igual, con `plan` y
`PM_PLAN_TOKEN`.

## Token de HCP (`TF_API_TOKEN`)

En los workflows se expone como `TF_TOKEN_app_terraform_io`, que es el nombre que lee Terraform. Es
el token del equipo owners de una organización de HCP **dedicada**: puede leer y escribir el estado
del workspace `homelab`. El plan de PR también lo usa ([A-1](seguridad.md#riesgos-aceptados)).
**Rotar:** HCP → Organization settings → Teams → owners → Regenerate token →
`gh secret set TF_API_TOKEN` en `production` y en `plan`.

En local (solo admin):

```sh
export TF_CLOUD_ORGANIZATION=<HCP_ORG>
read -rs TF_TOKEN_app_terraform_io && export TF_TOKEN_app_terraform_io
```

## Clave de Ansible (`ANSIBLE_SSH_KEY`) y cuenta `ops`

`ops` es la cuenta de arranque y de automatización de todas las VMs. cloud-init la crea con las
claves de `admins` y `service` de `projects.yaml`, y el rol `base` las vuelve a sincronizar en cada
`configure` (lista completa: quitar una clave la revoca). **Rotar:** genera un par nuevo, cambia
`service.ci.ssh_key` por PR, mergea (el `configure` de ese deploy aún entra con la clave vieja e
instala la nueva) y después cambia el secreto:

```sh
ssh-keygen -t ed25519 -f ci -C homelab-iac-ci -N ''
# PR: projects.yaml -> service.ci.ssh_key = contenido de ci.pub ; merge y espera al deploy
gh secret set ANSIBLE_SSH_KEY -R <ORG>/homelab-iac --env production < ci && shred -u ci
```

## Clave del plan (`PLAN_ENC_KEY`)

Cifra el artefacto del plan entre los jobs `plan` y `apply` ([R-09](seguridad.md#controles)). Se
puede rotar en cualquier momento salvo con un deploy en curso:
`openssl rand -base64 48 | gh secret set PLAN_ENC_KEY -R <ORG>/homelab-iac --env production`.

## Credenciales del MVP de dataspace

- `GHCR_READ_TOKEN`: PAT **clásico** (los fine-grained no sirven para ghcr) con **solo**
  `read:packages`, del usuario `GHCR_USER`. Las imágenes del MVP (`ghcr.io/teo-devops/*`) son
  privadas. Recomendado ([A-3](seguridad.md#riesgos-aceptados)): una cuenta máquina de GitHub a la
  que se da acceso de lectura solo a esos paquetes, y su token.
- `DATASPACE_MVP_DEPLOY_KEY`: deploy key **sin** escritura del repo `dataspace-mvp`.
- Las dos existen en la VM solo mientras dura el despliegue, y el rol `dataspace_mvp` las borra en un
  bloque `always` ([R-13](seguridad.md#controles)).
- **Rotar:** crea el token o la clave nuevos, `gh secret set …`, y borra el viejo en GitHub
  (Settings → Developer settings → Tokens; o `gh repo deploy-key delete`).

En local (break-glass `make configure`):

```sh
export GHCR_USER=<usuario>
read -rs GHCR_READ_TOKEN && export GHCR_READ_TOKEN
export DATASPACE_MVP_DEPLOY_KEY="$(cat ~/ruta/a/la/deploy-key)"
```

## PAT de los runners

Lo usa `runner/supervisor.sh` para pedir a GitHub configuraciones JIT de runner. Fine-grained, con
la organización como propietario del recurso y solo el permiso «Self-hosted runners: Read and
write». Vive en `/etc/homelab-runner/env` (root, `0600`). En el host de runners solo entran los
admins. Caduca: pon una fecha y un recordatorio. **Rotar:** crea uno nuevo, cámbialo en el fichero y
`systemctl restart 'homelab-runner@*'`.

## Túnel de Cloudflare

Hay dos credenciales:

- **Token del túnel.** Con él, cualquiera puede levantar un conector del túnel `homelab`, que
  recibiría el tráfico de los devs hacia sus rutas. `cloudflared service install` lo guarda en la
  unidad systemd del LXC del conector, y en ese LXC solo entran los admins. **Rotar:** en Networks →
  Tunnels → `homelab`, crea un túnel nuevo (`homelab-2`), instala su conector, mueve las rutas,
  comprueba que llegas y borra el viejo.
- **Secret de la OAuth App de GitHub.** Vive en Zero Trust → Settings → Authentication. Solo sirve
  para el login de las personas. **Rotar:** genera uno nuevo en la OAuth App, pégalo en Cloudflare,
  pulsa Test y borra el viejo en GitHub.

Para quitarle el acceso a **una persona**, mira
[operador.md](operador.md#alta-y-baja-de-una-persona).

## Lo que NO es una credencial

`terraform/certs/pve-root-ca.pem` (la CA del cluster, pública), las claves de host que publica el
artefacto `known_hosts` y las claves públicas de `projects.yaml`.
