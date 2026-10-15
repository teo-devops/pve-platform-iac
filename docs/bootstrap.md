# Puesta en marcha desde cero

**Para quién:** el admin, una sola vez (o al reconstruir la plataforma). Todo lo que **no vive en el
repo** (organización, ruleset, environments, HCP, runners, ACL de Proxmox y CA), paso a paso.

**Antes de empezar necesitas:** acceso root a un nodo de Proxmox VE 8.4 o posterior (probado con
9.x), ser owner de la organización de GitHub (o poder crearla), una cuenta en HCP Terraform y un host
pequeño en la infraestructura para los runners (LXC o VM con Docker: 2 vCPU y 4 GB bastan), una cuenta de
Cloudflare para la VPN de los devs (§10) y un bucket en tu SeaweedFS para las copias (§11). En tu máquina:
`gh` autenticado con permisos de admin (`gh auth refresh -s admin:org`), `terraform`, `python3` con
PyYAML, `jq` y `curl`.

**Cómo saber que ha salido bien:** `make preflight` en verde y un primer deploy correcto (§9).

En los comandos, sustituye `<ORG>` por la organización de GitHub y `<HCP_ORG>` por la de HCP.

Orden: §0 (Proxmox, con platform-proxmox) → §1–§9 (repo, GitHub, HCP, tokens, primer deploy) → §10 (acceso de los devs)
→ §11 (copias de seguridad).

## 0. Proxmox: lo que tiene que estar antes

Este repo no instala Proxmox: da por hecho un cluster sano (de 1 a N nodos).

### Opción recomendada: platform-proxmox

[platform-proxmox](https://github.com/teo-devops/platform-proxmox) lleva de los servidores sin
instalar a un cluster listo, a partir de un inventario de Ansible: instalación desatendida, repos,
ZFS, red, cluster, QDevice, admins con segundo factor, contenido `import` y copias. Al terminar:

```sh
make validate ENV=<entorno>     # en platform-proxmox
make handoff ENV=<entorno>      # imprime el bloque proxmox: de platform.yaml (§2)
```

### Si ya tienes un cluster

Comprueba que cumple lo mismo que deja platform-proxmox (el detalle de cada punto está en su
documentación):

1. **Proxmox VE 8.4 o posterior**, con los repos sin errores (`apt update` sin 401) y, con más de un
   nodo, en cluster con quórum (`pvecm status` → `Quorate: Yes`). Con un número par de nodos, un
   QDevice.
2. **Datastores con el mismo nombre en todos los nodos.** Las VMs se reparten por
   `vmid % número de nodos`. Con ZFS es `local-zfs`; con ext4/xfs, `local-lvm`.
3. **Contenido `import`** en el datastore de las imágenes (`image_datastore`), que no viene
   activado por defecto. Añádelo sin quitar los que ya tiene:
   `pvesm set local --content iso,vztmpl,backup,import`.
4. **El nombre e IP de cada nodo, definitivos.** El certificado del nodo los incluye (§3).
5. **Un DNS que responda** (`dig +short @<dns> github.com`): será el `network.dns` de las VMs.
6. **Si el bridge lleva `vlan_tag`**, tiene que ser VLAN-aware (`bridge-vlan-aware yes`).
7. **Admins con su usuario `@pve`** y TOTP **por usuario**, nunca en el realm (bloquea el realm
   entero). `root@pam` solo para emergencias.
8. **Copias** fuera del cluster (§11) y **nada expuesto a Internet** (`:8006`, SSH): la VPN, en §10.

**Comprobación:** `make preflight` (§9) verifica el TLS contra el endpoint y los permisos del token.

## 1. Organización de GitHub o cuenta personal

Dos formas de alojar tu instancia ([D-01](diseno.md#decisiones)):

| | **A. Organización** (recomendada para empresas) | **B. Cuenta personal, repo público** |
|---|---|---|
| Quién pide infraestructura | Miembros del equipo `colaboradores` (rol Read) con fork | Cualquiera con fork; el admin decide qué se planifica |
| Runners propios | Grupos limitados a los workflows de `main` | Runners del repo, sin limitación por workflow ([A-11](seguridad.md#riesgos-aceptados)) |
| Configuración de la instancia | Privada | Pública: nodos, IPs internas, usuarios ([A-12](seguridad.md#riesgos-aceptados)) |
| Coste en GitHub | Plan Team (rulesets y environments en un repo privado) | Gratis (en un repo público son gratis) |

### A. Organización

1. Crea la organización (Settings de tu cuenta → Organizations → New organization) con el plan
   **Team**: hacen falta rulesets y environments con restricciones de rama en un repo privado.
2. Base de permisos: los miembros no ven nada salvo lo que se les da; se pueden forkear repos
   privados (los devs trabajan con forks, [D-04](diseno.md#decisiones)):

   ```sh
   gh api -X PATCH orgs/<ORG> -f default_repository_permission=none \
     -F members_can_create_repositories=false -F members_can_fork_private_repositories=true
   ```
3. Equipos:

   ```sh
   gh api orgs/<ORG>/teams -f name=infra-admins -f privacy=closed      # admins
   gh api orgs/<ORG>/teams -f name=colaboradores -f privacy=closed     # devs y freelancers
   ```
4. Crea el repo privado `<ORG>/pve-platform-iac` desde la plantilla, súbelo y da permisos:

   ```sh
   gh repo create <ORG>/pve-platform-iac --private --template teo-devops/pve-platform-iac --clone
   cd pve-platform-iac && make init OWNER=@<ORG>/infra-admins     # tu configuración, desde examples/
   # Si el repo ya existe en una cuenta personal, en vez de crearlo, transfiérelo (conserva
   # historial, PR e issues; GitHub redirige la URL vieja):
   #   gh api -X POST repos/<usuario>/pve-platform-iac/transfer -f new_owner=<ORG>
   gh api -X PUT orgs/<ORG>/teams/infra-admins/repos/<ORG>/pve-platform-iac -f permission=admin
   gh api -X PUT orgs/<ORG>/teams/colaboradores/repos/<ORG>/pve-platform-iac -f permission=pull   # Read
   ```
5. Workflows de forks en repos privados: se ejecutan, sin secretos ni token de escritura, y con
   aprobación:

   ```sh
   gh api -X PUT repos/<ORG>/pve-platform-iac/actions/permissions/fork-pr-workflows-private-repos \
     -F run_workflows_from_fork_pull_requests=true -F send_write_tokens_to_workflows=false \
     -F send_secrets_and_variables=false -F require_approval_for_fork_pr_workflows=true
   ```

### B. Cuenta personal con repo público

1. Crea el repo desde la plantilla y pon tu usuario como dueño del código:

   ```sh
   gh repo create <usuario>/pve-platform-iac --public --template teo-devops/pve-platform-iac --clone
   cd pve-platform-iac && make init OWNER=@<usuario>
   ```
2. **Colaboradores: solo admins.** En una cuenta personal, un colaborador siempre tiene permiso de
   escritura y podría lanzar workflows desde su rama sobre tus runners. Los devs y freelancers no
   necesitan ningún rol: hacen fork y abren un PR.
3. Workflows de personas de fuera: siempre con aprobación, y el `GITHUB_TOKEN` en solo lectura por
   defecto:

   ```sh
   gh api -X PUT repos/<usuario>/pve-platform-iac/actions/permissions/workflow \
     -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
   ```
   Y en Settings → Actions → General → *Fork pull request workflows from outside collaborators*:
   **Require approval for all outside collaborators**.
4. Activa también: Settings → Code security → *Secret scanning* + *Push protection* y *Private
   vulnerability reporting*.
5. En los PR de personas de fuera, `pr-plan` **no planifica** hasta que un admin, después de leer
   el PR, le pone la etiqueta `plan`. Un push nuevo quita la etiqueta
   ([operador.md](operador.md#revisar-un-pr)).

## 2. platform.yaml y projects.yaml

Rellena todos los `TODO` (por PR, como cualquier cambio):

- `platform.yaml`: `proxmox.endpoint` (con un nombre o IP que esté en el certificado del nodo, ver
  §3), `nodes` (nombre → IP de gestión), `datastore`, `image_datastore` (debe admitir el contenido
  «import»: Datacenter → Storage → `local` → Content), `bridge`, `vlan_tag` y `sdn_zone`; y la red
  de las VMs (`prefix`, `cidr_bits`, `gateway`, `dns` y `reserved_ips`).
- `projects.yaml`: tu usuario de GitHub en `admins` con tu clave pública, la clave pública de la
  cuenta de servicio `ci` (genera el par: `ssh-keygen -t ed25519 -f ci -C pve-platform-iac-ci -N ''`; la
  privada va al secreto `ANSIBLE_SSH_KEY` en §5) y los proyectos.

`make check` tiene que pasar. `make preflight` avisa de los `TODO` que queden.

## 3. CA del cluster Proxmox (TLS verificado)

El provider valida el certificado de Proxmox (`insecure = false`, [R-03](seguridad.md#controles)).

1. Copia la CA del cluster al repo (es pública):

   ```sh
   scp root@<nodo>:/etc/pve/pve-root-ca.pem terraform/certs/pve-root-ca.pem
   ```
2. Comprueba que el nombre de `proxmox.endpoint` está en el certificado del nodo:

   ```sh
   ssh root@<nodo> openssl x509 -in /etc/pve/nodes/<nodo>/pve-ssl.pem -noout -ext subjectAltName
   ```
   Ahí salen el nombre, el FQDN y las IPs del nodo. Usa uno de ellos en `endpoint`.
3. Si el nodo usa un certificado propio (ACME o de tu CA), pon en `pve-root-ca.pem` la CA que lo
   emite.
4. `make preflight` → «TLS verificado contra …».

## 4. Ruleset de main

PR obligatorio, aprobación de CODEOWNERS, checks verdes, sin force-push ni borrado, y **sin bypass**
(tampoco para admins: el admin también entra por PR).

```sh
gh api -X POST repos/<ORG>/pve-platform-iac/rulesets --input - <<'JSON'
{
  "name": "main protegida",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [],
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 1,
      "require_code_owner_review": true,
      "dismiss_stale_reviews_on_push": true,
      "require_last_push_approval": true,
      "required_review_thread_resolution": false}},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": true,
      "required_status_checks": [
        {"context": "peticiones y catalogo"},
        {"context": "terraform"},
        {"context": "ansible"},
        {"context": "workflows (actionlint)"}]}}
  ]
}
JSON
```

**Con un solo admin**, GitHub no deja aprobar el PR propio: el ruleset de arriba bloquearía todos sus
PR. Mientras sea así, usa `"required_approving_review_count": 0`, `"require_code_owner_review":
false` y `"require_last_push_approval": false`. El PR y los checks siguen siendo obligatorios, y
nadie puede empujar a `main` ni saltarse el ruleset. Apúntalo en el registro de break-glass
([operador.md](operador.md#registro-de-break-glass)) y súbelo a 1 aprobación de CODEOWNERS en cuanto
haya un segundo admin.

## 5. Environments y secretos

Dos environments. **Ningún secreto a nivel de repo** ([R-10](seguridad.md#controles)).

```sh
R=<ORG>/pve-platform-iac
# production: solo despliega desde main
gh api -X PUT repos/$R/environments/production --input - <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
gh api -X POST repos/$R/environments/production/deployment-branch-policies -f name=main -f type=branch
# plan: lo usa pr-plan (pull_request_target corre en main)
gh api -X PUT repos/$R/environments/plan --input - <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
gh api -X POST repos/$R/environments/plan/deployment-branch-policies -f name=main -f type=branch
```

Secretos (cada uno se pega por la entrada estándar: no queda en el historial). Qué es cada uno y
cómo rotarlo: [credenciales.md](credenciales.md).

```sh
gh secret set PM_APPLY_TOKEN           -R $R --env production   # iac@pve!apply=<uuid>  (§8)
gh secret set TF_API_TOKEN             -R $R --env production   # token de HCP          (§7)
gh secret set ANSIBLE_SSH_KEY          -R $R --env production < ci   # privada de la cuenta ci (§2)
openssl rand -base64 48 | gh secret set PLAN_ENC_KEY -R $R --env production
gh secret set GHCR_READ_TOKEN          -R $R --env production   # PAT clasico, solo read:packages
gh secret set DATASPACE_MVP_DEPLOY_KEY -R $R --env production < dataspace-mvp-deploy   # ver abajo
gh secret set PM_PLAN_TOKEN            -R $R --env plan         # iac@pve!plan=<uuid>   (§8)
gh secret set TF_API_TOKEN             -R $R --env plan         # el mismo token de HCP
shred -u ci dataspace-mvp-deploy

gh variable set TF_CLOUD_ORGANIZATION -R $R --body <HCP_ORG>
gh variable set GHCR_USER             -R $R --body <usuario dueño del token de ghcr>
```

Deploy key de `dataspace-mvp` (solo lectura):

```sh
ssh-keygen -t ed25519 -f dataspace-mvp-deploy -C pve-platform-iac -N ''
gh repo deploy-key add dataspace-mvp-deploy.pub -R teo-devops/dataspace-mvp -t pve-platform-iac   # sin --allow-write
```

## 6. Runners propios

**Con organización (§1 A):** dos **grupos de runners**, cada uno limitado a este repo y a sus
workflows de `main` ([R-08](seguridad.md#controles)):

```sh
RID=$(gh api repos/<ORG>/pve-platform-iac --jq .id)
gh api orgs/<ORG>/actions/runner-groups -f name=platform-plan -f visibility=selected \
  -F "selected_repository_ids[]=$RID" -F allows_public_repositories=false -F restricted_to_workflows=true \
  -f "selected_workflows[]=<ORG>/pve-platform-iac/.github/workflows/pr-plan.yml@refs/heads/main"
gh api orgs/<ORG>/actions/runner-groups -f name=platform-apply -f visibility=selected \
  -F "selected_repository_ids[]=$RID" -F allows_public_repositories=false -F restricted_to_workflows=true \
  -f "selected_workflows[]=<ORG>/pve-platform-iac/.github/workflows/deploy.yml@refs/heads/main" \
  -f "selected_workflows[]=<ORG>/pve-platform-iac/.github/workflows/drift.yml@refs/heads/main"
gh api orgs/<ORG>/actions/runner-groups --jq '.runner_groups[] | "\(.id) \(.name) restringido=\(.restricted_to_workflows)"'
```

> [!IMPORTANT]
> Comprueba en la última salida que `restringido=true`. Si tu plan no lo admite, la API lo ignora
> en silencio: anótalo como en el riesgo [A-6](seguridad.md#riesgos-aceptados). La barrera principal
> sigue siendo que los devs no pueden crear ramas ([D-04](diseno.md#decisiones)).

**Con cuenta personal (§1 B):** no hay grupos; los runners se registran en el repo (`GH_REPO` en
[runner/README.md](../runner/README.md)). La barrera son el opt-in de abajo, que los jobs con runner
propio solo se disparan desde `main` (o con la etiqueta `plan`), y que no haya más colaboradores
que los admins ([A-11](seguridad.md#riesgos-aceptados)).

Después, en el host de runners, sigue [runner/README.md](../runner/README.md): imagen, PAT,
servicios systemd y cortafuegos. Los jobs con runner propio están **apagados** hasta que los
actives:

```sh
gh variable set PLATFORM_RUNNERS -R <OWNER>/pve-platform-iac --body true
```

## 7. HCP Terraform

1. Crea una organización de HCP **solo para esto** (`<HCP_ORG>`): el token del plan Free tiene
   alcance de organización, así que mejor que no haya nada más en ella.
2. Crea el workspace `pve-platform` (CLI-driven; si quieres otro nombre, ponlo en la variable
   del repo `TF_WORKSPACE` y expórtalo en local) y ponlo en **Local**: Settings → General → Execution
   Mode → Local. Así, HCP solo guarda el estado y hace de lock ([D-03](diseno.md#decisiones)).
3. Token: Organization settings → Teams → owners → Team API token. Va a `TF_API_TOKEN` (§5).
4. Prueba en local:

   ```sh
   export TF_CLOUD_ORGANIZATION=<HCP_ORG>
   read -rs TF_TOKEN_app_terraform_io && export TF_TOKEN_app_terraform_io
   terraform -chdir=terraform init
   ```

## 8. Proxmox: tokens, pools y ACL

```sh
make proxmox-acl > acl.sh        # revisalo: son los comandos exactos
scp acl.sh root@<nodo>: && ssh root@<nodo> bash acl.sh
```

El script crea el rol `IaCApply`, el usuario `iac@pve` (sin contraseña), un pool por proyecto, los
tokens `apply` y `plan` (con privsep: **solo** las ACL que se les dan) y las ACL. Al final comprueba
que no hay nada en `/`. Los secretos de los tokens salen **una sola vez**: van directos a §5.

Comprobación desde tu máquina:

```sh
read -rs TF_VAR_pm_api_token && export TF_VAR_pm_api_token   # el de apply, y luego el de plan
make preflight     # "el token no tiene permisos en '/'" y la lista de rutas
```

Si `pveum role add` se queja de un privilegio que no existe, tu versión de Proxmox es anterior a
la 9 (p. ej. `VM.GuestAgent.Audit` era `VM.Monitor`). Ajusta `APPLY_PRIVS` en `scripts/iac` por PR
y anótalo en el CHANGELOG.

## 9. Primer deploy

1. `make preflight` en verde.
2. PR con la primera petición (p. ej. un MVP: [dataspace.md](dataspace.md)). Comprueba que
   `pr-validate` pasa y que `pr-plan` comenta el plan.
3. Merge → `deploy`: `plan`, `apply`, `known-hosts` (avisa «primer deploy: TOFU») y `configure`.
4. `make ssh NAME=<vm>` desde tu máquina.
5. Lanza `drift` a mano (Actions → drift → Run workflow): tiene que decir «Sin deriva».
6. Anota la fecha en el README (sección «Estado»).

## 10. Acceso de los devs a las VMs (VPN)

Las VMs viven en la red privada de la infraestructura. Para **pedirlas** no hace falta red (es un PR), pero
para **entrar** por `make ssh` o `make tunnel` sí. La VPN es **Cloudflare Zero Trust**
([D-13](diseno.md#decisiones)): no se abre ningún puerto del router.

```
portátil del dev                        Cloudflare                       red interna
WARP (login con GitHub) ──► Gateway: ¿quién eres? ¿puedes? ──► túnel ──► cloudflared ──► VM :22
                                                                (saliente)   (LXC)
```

- `cloudflared` corre en un LXC de la plataforma y abre un túnel **saliente** hacia Cloudflare.
- Cada dev instala el cliente **WARP** y entra en la organización de Zero Trust con su cuenta de
  GitHub. Desde ese momento, el tráfico hacia la red de las VMs va por el túnel.
- Las **políticas de Gateway** deciden a qué puede llegar cada persona: los devs, solo al `:22` de
  la red de las VMs; los admins, también a la gestión de Proxmox.

Requisitos que no cambian: solo la red de las VMs y solo el `:22` para los devs, nunca `:8006`; un
acceso por persona, revocable; el admin en una política aparte.

**Antes de empezar:** una cuenta de Cloudflare (no hace falta tener un dominio en ella) y un LXC
pequeño en la infraestructura para el conector (Debian/Ubuntu, 1 vCPU, 512 MB). El LXC tiene que llegar a la
red de las VMs y, para los admins, a la de gestión. Créalo **a mano y fuera de los pools del repo**:
si lo gestionara el pipeline, un `apply` podría cortar el acceso. No uses el host de runners: allí
vive el PAT (A-5).

En los comandos, `<TEAM>` es el nombre de tu organización de Zero Trust, `<VMS>` la red de las VMs
(`network.prefix` de `platform.yaml` + `.0/24`) y `<GESTION>` la red de gestión de los nodos.

1. **Organización de Zero Trust.** dash.cloudflare.com → Zero Trust. Elige el nombre del equipo
   (`<TEAM>`; tu portal será `https://<TEAM>.cloudflareaccess.com`) y el plan **Free** (hasta 50
   usuarios).
2. **Login con GitHub.** La identidad es la misma que en `projects.yaml`.
   - En GitHub, crea una OAuth App (de la organización, o en tu cuenta → Settings → Developer
     settings → OAuth Apps), con:
     - Homepage: `https://<TEAM>.cloudflareaccess.com`
     - Callback: `https://<TEAM>.cloudflareaccess.com/cdn-cgi/access/callback`
   - En Zero Trust: Settings → Authentication → Login methods → Add new → GitHub. Pega el Client ID
     y el secret, y pulsa **Test**.
3. **Quién puede conectar un dispositivo.** Settings → WARP Client → Device enrollment permissions
   → Manage → regla **Allow**:
   - Include: *Emails* con la lista de personas (las de `admins` y `members` de `projects.yaml`).
   - Con organización de GitHub, en su lugar: *GitHub organization* = `<ORG>`.
   - Login method: GitHub.
4. **Túnel.** Networks → Tunnels → Create a tunnel → *Cloudflared* → nombre `platform`. El panel
   muestra el comando con el token: ejecútalo **en el LXC del conector**. Es, más o menos:

   ```sh
   curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
   echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
     > /etc/apt/sources.list.d/cloudflared.list
   apt update && apt install -y cloudflared
   cloudflared service install <TOKEN-DEL-TUNEL>      # queda como servicio systemd
   ```
   El token es una credencial ([credenciales.md](credenciales.md#túnel-de-cloudflare)). En la
   pestaña de rutas del túnel (*CIDR* / *Private networks*), añade `<VMS>` y `<GESTION>`. El túnel
   tiene que salir como **HEALTHY**.
5. **Qué tráfico va por WARP.** Settings → WARP Client → Device settings → perfil Default → Split
   Tunnels. Por defecto está en modo *Exclude*, y **excluye las redes privadas**, que es justo donde
   están `<VMS>` y `<GESTION>`. Cámbialo a modo **Include** con solo `<VMS>` y `<GESTION>`. Así, por
   Cloudflare pasa solo el tráfico hacia la infraestructura, y el resto sale por la red normal del dev.
6. **Proxy de Gateway.** Settings → Network → activa el proxy **TCP**. Sin él no se aplican las
   políticas por identidad a las redes privadas.
7. **Políticas.** Gateway → Firewall policies → **Network**, en este orden (se evalúan de arriba
   abajo):

   | # | Nombre | Acción | Condiciones |
   |---|---|---|---|
   | 1 | `admins-gestion` | Allow | Destination IP en `<GESTION>` **y** puerto `8006` o `22` **y** el email del usuario está en la lista de admins |
   | 2 | `devs-ssh-vms` | Allow | Destination IP en `<VMS>` **y** puerto `22` **y** el email del usuario está en la lista de devs y admins |
   | 3 | `platform-resto` | Block | Destination IP en `<VMS>` o en `<GESTION>` |

   Si quieres que nadie llegue siquiera a las VMs de otros proyectos, sustituye la regla 2 por una
   por proyecto: destino = el rango de IP de ese proyecto en `projects.yaml`, usuarios = sus
   `members`. Eso cierra el acceso de cada **persona** a otros proyectos; entre las propias VMs,
   la red sigue plana ([A-9](seguridad.md#riesgos-aceptados)). Esas listas se mantienen a mano,
   junto con `projects.yaml` ([operador.md](operador.md#alta-y-baja-de-una-persona)).
8. **Prueba como dev**, desde un portátil que no sea el del admin (lo que tiene que hacer cada dev
   está en [inicio-rapido.md](inicio-rapido.md)):

   ```sh
   warp-cli registration new <TEAM>     # abre el navegador: login con GitHub
   warp-cli connect && warp-cli status  # "Connected"
   ```

**Comprobación:**
- Con un usuario dev: `make ssh NAME=<vm-de-su-proyecto>` entra, y `curl -k
  https://<nodo>:8006` no llega.
- Con un admin: llega a `:8006`.
- En Zero Trust → Logs → Gateway → Network se ven el *allow* y el *block*.

## 11. Copias de seguridad: Proxmox Backup Server sobre SeaweedFS (S3)

Proxmox VE no escribe copias directamente en S3. Quien lo hace es **Proxmox Backup Server (PBS) 4**,
con un datastore cuyo *backend* es un bucket S3 ([D-14](diseno.md#decisiones)):

```
nodos PVE ──vzdump──► PBS (VM, caché local 64–128 GiB) ──HTTPS S3──► SeaweedFS (bucket pbs-platform)
             incremental, cifrado en el nodo         deduplicado              otra máquina
```

- PBS deduplica por bloques: tras la primera copia, cada copia diaria solo sube lo que ha cambiado.
- La copia se **cifra en el nodo** de Proxmox antes de salir. Ni PBS ni SeaweedFS ven los datos en
  claro.

**Antes de empezar:**
- **SeaweedFS en otro hardware**, no en este Proxmox: si cae el host, una copia que vive en él cae
  con él.
- El **S3 de SeaweedFS con HTTPS**: PBS rechaza HTTP. Vale un certificado autofirmado, porque PBS
  admite fijar su huella.
- Una **VM para PBS**: 2 vCPU, 4 GB, 32 GB de sistema y **un segundo disco de 64–128 GiB para la
  caché**. La caché es obligatoria, aunque los datos vivan en S3. Créala a mano, **fuera de los
  pools del repo**, igual que el LXC de Cloudflare.

En los comandos: `<S3>` es el host del S3 de SeaweedFS, `<PBS>` la IP de la VM de PBS y
`pbs-platform` el bucket.

1. **Bucket y credencial en SeaweedFS.** Crea un bucket solo para esto y una identidad limitada a
   él:

   ```sh
   echo 's3.bucket.create -name pbs-platform' | weed shell
   ```
   En el `s3.json` de identidades (el que pasas con `weed s3 -config`), añade una entrada y
   reinicia el S3:

   ```json
   {"name": "pbs-platform",
    "credentials": [{"accessKey": "<AK>", "secretKey": "<SK>"}],
    "actions": ["Read:pbs-platform", "Write:pbs-platform", "List:pbs-platform"]}
   ```
   PBS necesita leer, escribir, listar y **borrar** objetos (su recolector de basura borra los
   bloques que ya no usa ninguna copia). Pruébalo antes de seguir:

   ```sh
   export AWS_ACCESS_KEY_ID=<AK> AWS_SECRET_ACCESS_KEY=<SK>
   S3="aws --endpoint-url https://<S3>:8333 s3"     # añade --no-verify-ssl si el certificado es autofirmado
   echo hola > t && $S3 cp t s3://pbs-platform/t && $S3 ls s3://pbs-platform/ && $S3 rm s3://pbs-platform/t
   ```
   **No pongas** en el bucket reglas de expiración ni de ciclo de vida: borrarían bloques que siguen
   en uso y romperían las copias. Si el certificado es autofirmado, saca su huella:
   `openssl s_client -connect <S3>:8333 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256`.
2. **Instala PBS 4** en la VM (ISO de proxmox.com) y prepara la caché en el segundo disco:

   ```sh
   mkfs.ext4 /dev/sdb && mkdir -p /mnt/pbs-cache
   echo '/dev/sdb /mnt/pbs-cache ext4 defaults 0 2' >> /etc/fstab && mount -a
   ```
3. **Endpoint S3 y datastore** (en PBS). Se puede hacer desde la GUI (Configuration → Remotes → S3
   Endpoints → Add, marcando *Path Style*) o por CLI:

   ```sh
   proxmox-backup-manager s3 endpoint create seaweedfs \
     --endpoint '<S3>' --port 8333 --region us-east-1 --path-style true \
     --access-key '<AK>' --secret-key '<SK>' \
     --fingerprint '<huella sha256, solo si es autofirmado>'
   proxmox-backup-manager datastore create platform /mnt/pbs-cache/platform \
     --backend type=s3,client=seaweedfs,bucket=pbs-platform
   ```
   SeaweedFS usa direcciones *path-style* (`https://<S3>/<bucket>/…`), de ahí `--path-style true`.
   Si algún flag no coincide en tu versión de PBS, usa la GUI.
4. **Retención, limpieza y verificación** (en PBS, Datastore → `platform`):

   ```sh
   proxmox-backup-manager prune-job create platform-retencion --store platform --schedule daily \
     --keep-daily 7 --keep-weekly 4 --keep-monthly 6
   proxmox-backup-manager datastore update platform --gc-schedule daily
   proxmox-backup-manager verify-job create platform-verificar --store platform --schedule weekly \
     --ignore-verified true --outdated-after 30
   ```
   Verificar implica descargar los bloques desde SeaweedFS: con `--outdated-after 30`, cada bloque
   se comprueba como mucho una vez al mes.
5. **Usuario de PBS para Proxmox VE**, con permiso de hacer copias y nada más:

   ```sh
   proxmox-backup-manager user create pve@pbs
   proxmox-backup-manager user generate-token pve@pbs backup         # el secreto sale UNA vez
   proxmox-backup-manager acl update /datastore/platform DatastoreBackup --auth-id 'pve@pbs!backup'
   proxmox-backup-manager cert info | grep -i fingerprint             # huella de PBS, para el paso 6
   ```
6. **Añade PBS como storage en Proxmox VE** (en un nodo; con cluster, se replica solo), con
   **cifrado en el cliente**:

   ```sh
   pvesm add pbs pbs-platform --server <PBS> --datastore platform \
     --username 'pve@pbs!backup' --password '<secreto del token>' \
     --fingerprint '<huella de PBS>' --encryption-key autogen
   ```
   > [!IMPORTANT]
   > `autogen` crea la clave en `/etc/pve/priv/storage/pbs-platform.enc`. **Sin esa clave no se puede
   > restaurar ninguna copia**, y si cae el host, cae con él. Guarda su contenido **fuera del
   > la infraestructura** (gestor de contraseñas) ahora mismo
   > ([credenciales.md](credenciales.md#copias-de-seguridad)).
7. **Trabajo de copia** (Datacenter → Backup → Add, o por CLI): cada noche, todas las VMs y LXC
   menos la de PBS (no tiene sentido copiar PBS dentro de sí mismo).

   ```sh
   pvesh create /cluster/backup --id platform-diario --schedule '02:30' --storage pbs-platform \
     --all 1 --exclude <vmid-de-PBS> --mode snapshot --notes-template '{{guestname}}'
   ```
   A las 02:30 no suele haber deploys. Si coincide uno, Terraform puede encontrarse la VM bloqueada
   por la copia ([runbooks/apply-fallido.md](runbooks/apply-fallido.md): `VM is locked`).
8. **Configuración de los nodos** (opcional, recomendable). `/etc/pve` (ACL, storages, usuarios,
   la clave de cifrado) no entra en las copias de VMs. Puedes copiarlo con `proxmox-backup-client`
   desde un timer de systemd en cada nodo:

   ```sh
   PBS_REPOSITORY='pve@pbs!backup@<PBS>:platform' PBS_PASSWORD='<secreto>' PBS_FINGERPRINT='<huella>' \
     proxmox-backup-client backup pve-etc.pxar:/etc/pve --keyfile /etc/pve/priv/storage/pbs-platform.enc
   ```

**Comprobación:**
- Lanza el trabajo a mano (Datacenter → Backup → `platform-diario` → Run now). Tiene que terminar
  en `OK`, y en SeaweedFS tienen que aparecer objetos con el prefijo `platform/`
  (`$S3 ls s3://pbs-platform/ --recursive | head`).
- Después, **restaura una VM de prueba**, como en
  [runbooks/restaurar-vm.md](runbooks/restaurar-vm.md#prueba-mensual). Una copia que no se ha
  restaurado nunca no está probada.
