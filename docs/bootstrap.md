# Puesta en marcha desde cero

**Para quién:** el admin, una sola vez (o al reconstruir la plataforma). Todo lo que **no vive en el
repo** (organización, ruleset, environments, HCP, runners, ACL de Proxmox y CA), paso a paso.

**Antes de empezar necesitas:** acceso root a un nodo de Proxmox VE 8.4 o posterior (probado con
9.x), ser owner de la organización de GitHub (o poder crearla), una cuenta en HCP Terraform y un host
pequeño en el homelab para los runners (LXC o VM con Docker: 2 vCPU y 4 GB bastan), una cuenta de
Cloudflare para la VPN de los devs (§10) y un bucket en tu SeaweedFS para las copias (§11). En tu máquina:
`gh` autenticado con permisos de admin (`gh auth refresh -s admin:org`), `terraform`, `python3` con
PyYAML, `jq` y `curl`.

**Cómo saber que ha salido bien:** `make preflight` en verde y un primer deploy correcto (§9).

En los comandos, sustituye `<ORG>` por la organización de GitHub y `<HCP_ORG>` por la de HCP.

Orden: §0 (Proxmox) → §1–§9 (repo, GitHub, HCP, tokens, primer deploy) → §10 (acceso de los devs)
→ §11 (copias de seguridad).

## 0. Proxmox: lo que tiene que estar antes

El repo no instala ni configura Proxmox: da por hecho un host o cluster sano. Esto se hace **una vez
por nodo**, como root en la consola o por SSH, y siempre **con acceso a la consola física o
fuera de banda** a mano: un error en la red te deja sin acceso al nodo.

1. **Instalación (PVE 9.x).** Decide aquí dos cosas que después cuesta cambiar:
   - **Disco:** con ZFS (`ashift=12`, `compression=lz4`), el datastore de las VMs se llama
     `local-zfs`; con ext4/xfs, `local-lvm`. Es el valor de `datastore` en `homelab.yaml`. ZFS
     `RAID0` con un solo disco **no tiene redundancia**: si muere el disco, se pierden sus VMs (ver
     el paso 9).
   - **Nombre (FQDN) e IP estática definitivos.** El certificado del nodo (`pve-ssl.pem`) incluye
     ambos y es lo que valida el provider (§3). Si cambian después: `pvecm updatecerts --force` y
     repite §3.
2. **Repositorios sin suscripción.** PVE 9 (Debian 13 «trixie») usa ficheros deb822 `.sources`;
   los repos enterprise sin suscripción hacen fallar `apt update` con un 401:

   ```sh
   cd /etc/apt/sources.list.d
   for f in pve-enterprise.sources ceph.sources; do
     [ -f "$f" ] && ! grep -qi '^Enabled: *false' "$f" && printf 'Enabled: false\n' >> "$f"
   done
   cat > pve-no-subscription.sources <<'EOF'
   Types: deb
   URIs: http://download.proxmox.com/debian/pve
   Suites: trixie
   Components: pve-no-subscription
   Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
   EOF
   apt update && apt full-upgrade -y
   ```
   `Enabled: false` va **sin** línea en blanco delante: en deb822 una línea en blanco separa
   entradas, y apt lo leería como una entrada vacía y daría error. Con PVE 8 el nombre es
   `bookworm` y los ficheros son `.list`.
3. **Memoria de ZFS (solo con ZFS).** El caché ARC compite con las VMs por la RAM.
   `cat /sys/module/zfs/parameters/zfs_arc_max`: si sale `0` (sin límite), fíjalo (aquí, 6 GiB) y
   reinicia:

   ```sh
   echo "options zfs zfs_arc_max=$((6*1024**3))" > /etc/modprobe.d/zfs.conf && update-initramfs -u
   ```
4. **Red.** El instalador crea `vmbr0` sobre la NIC. Si `homelab.yaml` lleva `vlan_tag`, el bridge
   tiene que admitir VLAN. Edita `/etc/network/interfaces` y aplícalo con `ifreload -a`, guardando
   antes una copia:

   ```
   iface vmbr0 inet static
       ...
       bridge-vlan-aware yes
       bridge-vids 2-4094
   ```
   Si el NIC es uno solo, por él pasan la gestión, las VMs y corosync: es suficiente en un homelab,
   pero no lo satures con copias de seguridad en horario de trabajo.
5. **DNS.** Comprueba que el servidor que vas a poner en `network.dns` responde de verdad. Muchos
   routers dan la puerta de enlace, pero no sirven DNS:

   ```sh
   dig +short @<dns> github.com     # tiene que devolver IPs
   ```
   Haz lo mismo con el `/etc/resolv.conf` de cada nodo: sin DNS, el nodo no puede descargar la
   imagen base.
6. **Almacenamiento de la imagen base.** El datastore `image_datastore` tiene que admitir el
   contenido `import`, que no viene activado por defecto. **Añádelo a los que ya tenga**, sin
   quitar ninguno:

   ```sh
   pvesm status --content import                     # si 'local' no sale, falta
   grep -A3 '^dir: local$' /etc/pve/storage.cfg      # mira su línea 'content'
   pvesm set local --content iso,vztmpl,backup,import   # la lista que tenía + import
   ```
   Las VMs se reparten entre los nodos por `vmid % número de nodos`. Por eso `datastore` e
   `image_datastore` tienen que existir **con el mismo nombre en todos los nodos**.
7. **Cluster (solo con más de un nodo).**

   ```sh
   pvecm create <nombre>                    # en el primero; máximo 15 caracteres (límite de corosync)
   pvecm add <ip-del-primero> --use_ssh     # en cada uno de los demás (o --fingerprint <sha256>)
   pvecm status                             # "Quorate: Yes" y todos los votos
   ```
   - **Con dos nodos**, si uno cae, el otro pierde el quórum y deja de aceptar cambios. Añade un
     QDevice en una tercera máquina (`pvecm qdevice setup <ip>`) o asume esa limitación.
   - `/etc/pve` se replica entre los nodos. Las ACL, `storage.cfg` y los usuarios se cambian **una
     sola vez**, en cualquier nodo.
   - Todos los nodos comparten la CA del cluster: la de §3 vale para todos.
8. **Tu cuenta de admin en Proxmox.** No uses `root@pam` en el día a día: déjalo para la consola y
   las emergencias.

   ```sh
   pveum user add <tu-usuario>@pve && pveum passwd <tu-usuario>@pve
   pveum acl modify / -user <tu-usuario>@pve -role Administrator
   ```
   Activa el segundo factor **por usuario**, cada uno desde su cuenta (Datacenter → Permissions →
   Two Factor → Add → TOTP). **No** lo actives en el realm (`pveum realm modify pve --tfa …`). Es el
   mecanismo antiguo: exige que el admin cargue antes la clave de cada usuario, y si falta, deja
   bloqueado el realm entero (`missing required 2nd keys` en `journalctl -u pvedaemon`). Para
   deshacerlo: `pveum realm modify pve --delete tfa`.
   En la pantalla de login, el usuario va **sin** `@pve` y el realm se elige en el desplegable.
9. **Copias de seguridad.** Terraform puede recrear una VM, pero no sus datos. Sin almacenamiento
   compartido ni replicación, si cae un disco se pierden sus VMs. Las copias van a **Proxmox
   Backup Server con un datastore en S3 (SeaweedFS)**: se montan en el §11, cuando ya existan las
   primeras VMs.
10. **Capacidad.** Reserva en cada nodo unos 2 hilos y la RAM del sistema y del ARC, y deja libre
    entre un 15 % y un 20 % del pool ZFS: por encima del 80–85 % de ocupación, ZFS va mucho más
    lento. La RAM es lo que limita cuántas VMs caben, no la CPU. Antes de pedir un `ds-mvp-kind`
    (16 GB), comprueba que cabe en el nodo que le toca (`free -g`): el reparto es por `vmid`, no por
    espacio libre.
11. **Exposición.** Ni `:8006` ni el SSH de los nodos se abren a Internet. Para administrar desde
    fuera, usa la VPN (§10).

**Comprobación:**

```sh
pveversion                                  # 9.x
apt update                                  # sin 401
pvecm status                                # Quorate: Yes (con cluster)
pvesm status --content images,import        # datastore e image_datastore, activos
zpool status                                # ONLINE (con ZFS)
```

## 1. Organización de GitHub

1. Crea la organización (Settings de tu cuenta → Organizations → New organization) con el plan
   **Team**: hacen falta rulesets y environments con restricciones de rama en un repo privado
   ([D-01](diseno.md#decisiones)).
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
4. Crea el repo privado `<ORG>/homelab-iac`, súbelo y da permisos:

   ```sh
   gh repo create <ORG>/homelab-iac --private --source . --push
   # Si el repo ya existe en una cuenta personal (p. ej. teo-devops/homelab-iac), en vez de crearlo,
   # transfiérelo (conserva historial, PR e issues; GitHub redirige la URL vieja):
   #   gh api -X POST repos/teo-devops/homelab-iac/transfer -f new_owner=<ORG>
   #   git remote set-url origin https://github.com/<ORG>/homelab-iac.git
   gh api -X PUT orgs/<ORG>/teams/infra-admins/repos/<ORG>/homelab-iac -f permission=admin
   gh api -X PUT orgs/<ORG>/teams/colaboradores/repos/<ORG>/homelab-iac -f permission=pull   # Read
   ```
5. Workflows de forks en repos privados: se ejecutan, sin secretos ni token de escritura, y con
   aprobación:

   ```sh
   gh api -X PUT repos/<ORG>/homelab-iac/actions/permissions/fork-pr-workflows-private-repos \
     -F run_workflows_from_fork_pull_requests=true -F send_write_tokens_to_workflows=false \
     -F send_secrets_and_variables=false -F require_approval_for_fork_pr_workflows=true
   ```
6. En `.github/CODEOWNERS`, cambia `<ORG>` por la organización (por PR).

## 2. homelab.yaml y projects.yaml

Rellena todos los `TODO` (por PR, como cualquier cambio):

- `homelab.yaml`: `proxmox.endpoint` (con un nombre o IP que esté en el certificado del nodo, ver
  §3), `nodes` (nombre → IP de gestión), `datastore`, `image_datastore` (debe admitir el contenido
  «import»: Datacenter → Storage → `local` → Content), `bridge`, `vlan_tag` y `sdn_zone`; y la red
  de las VMs (`prefix`, `cidr_bits`, `gateway`, `dns` y `reserved_ips`).
- `projects.yaml`: tu usuario de GitHub en `admins` con tu clave pública, la clave pública de la
  cuenta de servicio `ci` (genera el par: `ssh-keygen -t ed25519 -f ci -C homelab-iac-ci -N ''`; la
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
gh api -X POST repos/<ORG>/homelab-iac/rulesets --input - <<'JSON'
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

Con un solo admin, `require_last_push_approval` impide que apruebe su propio último push: sus PR
los aprueba otro admin. Si de momento solo hay uno, quítalo y apúntalo en el registro de
break-glass ([operador.md](operador.md#registro-de-break-glass)).

## 5. Environments y secretos

Dos environments. **Ningún secreto a nivel de repo** ([R-10](seguridad.md#controles)).

```sh
R=<ORG>/homelab-iac
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
ssh-keygen -t ed25519 -f dataspace-mvp-deploy -C homelab-iac -N ''
gh repo deploy-key add dataspace-mvp-deploy.pub -R teo-devops/dataspace-mvp -t homelab-iac   # sin --allow-write
```

## 6. Runners del homelab

Dos **grupos de runners** de la organización, cada uno limitado a este repo y a sus workflows de
`main` ([R-08](seguridad.md#controles)):

```sh
RID=$(gh api repos/<ORG>/homelab-iac --jq .id)
gh api orgs/<ORG>/actions/runner-groups -f name=homelab-plan -f visibility=selected \
  -F "selected_repository_ids[]=$RID" -F allows_public_repositories=false -F restricted_to_workflows=true \
  -f "selected_workflows[]=<ORG>/homelab-iac/.github/workflows/pr-plan.yml@refs/heads/main"
gh api orgs/<ORG>/actions/runner-groups -f name=homelab-apply -f visibility=selected \
  -F "selected_repository_ids[]=$RID" -F allows_public_repositories=false -F restricted_to_workflows=true \
  -f "selected_workflows[]=<ORG>/homelab-iac/.github/workflows/deploy.yml@refs/heads/main" \
  -f "selected_workflows[]=<ORG>/homelab-iac/.github/workflows/drift.yml@refs/heads/main"
gh api orgs/<ORG>/actions/runner-groups --jq '.runner_groups[] | "\(.id) \(.name) restringido=\(.restricted_to_workflows)"'
```

> [!IMPORTANT]
> Comprueba en la última salida que `restringido=true`. Si tu plan no lo admite, la API lo ignora
> en silencio: anótalo como en el riesgo [A-6](seguridad.md#riesgos-aceptados). La barrera principal
> sigue siendo que los devs no pueden crear ramas ([D-04](diseno.md#decisiones)).

Después, en el host de runners, sigue [runner/README.md](../runner/README.md): imagen, PAT,
servicios systemd y cortafuegos.

## 7. HCP Terraform

1. Crea una organización de HCP **solo para esto** (`<HCP_ORG>`): el token del plan Free tiene
   alcance de organización, así que mejor que no haya nada más en ella.
2. Crea el workspace `homelab` (CLI-driven) y ponlo en **Local**: Settings → General → Execution
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

Las VMs viven en la red privada del homelab. Para **pedirlas** no hace falta red (es un PR), pero
para **entrar** por `make ssh` o `make tunnel` sí. La VPN es **Cloudflare Zero Trust**
([D-13](diseno.md#decisiones)): no se abre ningún puerto del router.

```
portátil del dev                        Cloudflare                       homelab
WARP (login con GitHub) ──► Gateway: ¿quién eres? ¿puedes? ──► túnel ──► cloudflared ──► VM :22
                                                                (saliente)   (LXC)
```

- `cloudflared` corre en un LXC del homelab y abre un túnel **saliente** hacia Cloudflare.
- Cada dev instala el cliente **WARP** y entra en la organización de Zero Trust con su cuenta de
  GitHub. Desde ese momento, el tráfico hacia la red de las VMs va por el túnel.
- Las **políticas de Gateway** deciden a qué puede llegar cada persona: los devs, solo al `:22` de
  la red de las VMs; los admins, también a la gestión de Proxmox.

Requisitos que no cambian: solo la red de las VMs y solo el `:22` para los devs, nunca `:8006`; un
acceso por persona, revocable; el admin en una política aparte.

**Antes de empezar:** una cuenta de Cloudflare (no hace falta tener un dominio en ella) y un LXC
pequeño en el homelab para el conector (Debian/Ubuntu, 1 vCPU, 512 MB). El LXC tiene que llegar a la
red de las VMs y, para los admins, a la de gestión. Créalo **a mano y fuera de los pools del repo**:
si lo gestionara el pipeline, un `apply` podría cortar el acceso. No uses el host de runners: allí
vive el PAT (A-5).

En los comandos, `<TEAM>` es el nombre de tu organización de Zero Trust, `<VMS>` la red de las VMs
(`network.prefix` de `homelab.yaml` + `.0/24`) y `<GESTION>` la red de gestión de los nodos.

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
4. **Túnel.** Networks → Tunnels → Create a tunnel → *Cloudflared* → nombre `homelab`. El panel
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
   Cloudflare pasa solo el tráfico hacia el homelab, y el resto sale por la red normal del dev.
6. **Proxy de Gateway.** Settings → Network → activa el proxy **TCP**. Sin él no se aplican las
   políticas por identidad a las redes privadas.
7. **Políticas.** Gateway → Firewall policies → **Network**, en este orden (se evalúan de arriba
   abajo):

   | # | Nombre | Acción | Condiciones |
   |---|---|---|---|
   | 1 | `admins-gestion` | Allow | Destination IP en `<GESTION>` **y** puerto `8006` o `22` **y** el email del usuario está en la lista de admins |
   | 2 | `devs-ssh-vms` | Allow | Destination IP en `<VMS>` **y** puerto `22` **y** el email del usuario está en la lista de devs y admins |
   | 3 | `homelab-resto` | Block | Destination IP en `<VMS>` o en `<GESTION>` |

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
nodos PVE ──vzdump──► PBS (VM, caché local 64–128 GiB) ──HTTPS S3──► SeaweedFS (bucket pbs-homelab)
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
`pbs-homelab` el bucket.

1. **Bucket y credencial en SeaweedFS.** Crea un bucket solo para esto y una identidad limitada a
   él:

   ```sh
   echo 's3.bucket.create -name pbs-homelab' | weed shell
   ```
   En el `s3.json` de identidades (el que pasas con `weed s3 -config`), añade una entrada y
   reinicia el S3:

   ```json
   {"name": "pbs-homelab",
    "credentials": [{"accessKey": "<AK>", "secretKey": "<SK>"}],
    "actions": ["Read:pbs-homelab", "Write:pbs-homelab", "List:pbs-homelab"]}
   ```
   PBS necesita leer, escribir, listar y **borrar** objetos (su recolector de basura borra los
   bloques que ya no usa ninguna copia). Pruébalo antes de seguir:

   ```sh
   export AWS_ACCESS_KEY_ID=<AK> AWS_SECRET_ACCESS_KEY=<SK>
   S3="aws --endpoint-url https://<S3>:8333 s3"     # añade --no-verify-ssl si el certificado es autofirmado
   echo hola > t && $S3 cp t s3://pbs-homelab/t && $S3 ls s3://pbs-homelab/ && $S3 rm s3://pbs-homelab/t
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
   proxmox-backup-manager datastore create homelab /mnt/pbs-cache/homelab \
     --backend type=s3,client=seaweedfs,bucket=pbs-homelab
   ```
   SeaweedFS usa direcciones *path-style* (`https://<S3>/<bucket>/…`), de ahí `--path-style true`.
   Si algún flag no coincide en tu versión de PBS, usa la GUI.
4. **Retención, limpieza y verificación** (en PBS, Datastore → `homelab`):

   ```sh
   proxmox-backup-manager prune-job create homelab-retencion --store homelab --schedule daily \
     --keep-daily 7 --keep-weekly 4 --keep-monthly 6
   proxmox-backup-manager datastore update homelab --gc-schedule daily
   proxmox-backup-manager verify-job create homelab-verificar --store homelab --schedule weekly \
     --ignore-verified true --outdated-after 30
   ```
   Verificar implica descargar los bloques desde SeaweedFS: con `--outdated-after 30`, cada bloque
   se comprueba como mucho una vez al mes.
5. **Usuario de PBS para Proxmox VE**, con permiso de hacer copias y nada más:

   ```sh
   proxmox-backup-manager user create pve@pbs
   proxmox-backup-manager user generate-token pve@pbs backup         # el secreto sale UNA vez
   proxmox-backup-manager acl update /datastore/homelab DatastoreBackup --auth-id 'pve@pbs!backup'
   proxmox-backup-manager cert info | grep -i fingerprint             # huella de PBS, para el paso 6
   ```
6. **Añade PBS como storage en Proxmox VE** (en un nodo; con cluster, se replica solo), con
   **cifrado en el cliente**:

   ```sh
   pvesm add pbs pbs-homelab --server <PBS> --datastore homelab \
     --username 'pve@pbs!backup' --password '<secreto del token>' \
     --fingerprint '<huella de PBS>' --encryption-key autogen
   ```
   > [!IMPORTANT]
   > `autogen` crea la clave en `/etc/pve/priv/storage/pbs-homelab.enc`. **Sin esa clave no se puede
   > restaurar ninguna copia**, y si cae el host, cae con él. Guarda su contenido **fuera del
   > homelab** (gestor de contraseñas) ahora mismo
   > ([credenciales.md](credenciales.md#copias-de-seguridad)).
7. **Trabajo de copia** (Datacenter → Backup → Add, o por CLI): cada noche, todas las VMs y LXC
   menos la de PBS (no tiene sentido copiar PBS dentro de sí mismo).

   ```sh
   pvesh create /cluster/backup --id homelab-diario --schedule '02:30' --storage pbs-homelab \
     --all 1 --exclude <vmid-de-PBS> --mode snapshot --notes-template '{{guestname}}'
   ```
   A las 02:30 no suele haber deploys. Si coincide uno, Terraform puede encontrarse la VM bloqueada
   por la copia ([runbooks/apply-fallido.md](runbooks/apply-fallido.md): `VM is locked`).
8. **Configuración de los nodos** (opcional, recomendable). `/etc/pve` (ACL, storages, usuarios,
   la clave de cifrado) no entra en las copias de VMs. Puedes copiarlo con `proxmox-backup-client`
   desde un timer de systemd en cada nodo:

   ```sh
   PBS_REPOSITORY='pve@pbs!backup@<PBS>:homelab' PBS_PASSWORD='<secreto>' PBS_FINGERPRINT='<huella>' \
     proxmox-backup-client backup pve-etc.pxar:/etc/pve --keyfile /etc/pve/priv/storage/pbs-homelab.enc
   ```

**Comprobación:**
- Lanza el trabajo a mano (Datacenter → Backup → `homelab-diario` → Run now). Tiene que terminar
  en `OK`, y en SeaweedFS tienen que aparecer objetos con el prefijo `homelab/`
  (`$S3 ls s3://pbs-homelab/ --recursive | head`).
- Después, **restaura una VM de prueba**, como en
  [runbooks/restaurar-vm.md](runbooks/restaurar-vm.md#prueba-mensual). Una copia que no se ha
  restaurado nunca no está probada.
