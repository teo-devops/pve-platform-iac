# Puesta en marcha desde cero

**Para quién:** el admin, una sola vez (o al reconstruir la plataforma). Todo lo que **no vive en el
repo** (organización, ruleset, environments, HCP, runners, ACL de Proxmox y CA), paso a paso.

**Antes de empezar necesitas:** acceso root a un nodo de Proxmox VE 8.4 o posterior (probado con
9.x), ser owner de la organización de GitHub (o poder crearla), una cuenta en HCP Terraform y un host
pequeño en el homelab para los runners (LXC o VM con Docker: 2 vCPU y 4 GB bastan). En tu máquina:
`gh` autenticado con permisos de admin (`gh auth refresh -s admin:org`), `terraform`, `python3` con
PyYAML, `jq` y `curl`.

**Cómo saber que ha salido bien:** `make preflight` en verde y un primer deploy correcto (§9).

En los comandos, sustituye `<ORG>` por la organización de GitHub y `<HCP_ORG>` por la de HCP.

Orden: §0 (Proxmox) → §1–§9 (repo, GitHub, HCP, tokens, primer deploy) → §10 (acceso de los devs).

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
9. **Copias de seguridad.** Terraform puede recrear una VM, pero no sus datos. Programa un trabajo
   de `vzdump` (Datacenter → Backup) hacia **otro disco u otra máquina** (NAS o Proxmox Backup
   Server): sin almacenamiento compartido ni replicación, si cae un disco se pierden sus VMs.
   Una VM restaurada conserva sus claves de host. Si no las conserva:
   [runbooks/clave-de-host-cambiada.md](runbooks/clave-de-host-cambiada.md).
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
para **entrar** por `make ssh` o `make tunnel` sí. Nada del homelab se abre a Internet.

Requisitos, uses la VPN que uses (WireGuard, Tailscale, Headscale…):

- **Solo la red de las VMs** (`network.prefix` de `homelab.yaml`) y **solo el puerto 22**. Nunca la
  red de gestión de Proxmox (`:8006`) ni el resto de la LAN.
- **Un acceso por persona**, que se pueda revocar. Al dar de baja a alguien
  ([operador.md](operador.md#alta-y-baja-de-una-persona)), quítale también la VPN.
- **El admin** sí puede llegar a la red de gestión. Usa un perfil distinto del de los devs.

Ejemplo con Tailscale: un *subnet router* en el homelab que anuncia `<prefix>.0/24`, y una ACL que
solo permite `tcp:22` hacia esa red al grupo de los devs.

> [!NOTE]
> La VPN decide **quién llega** a la red de las VMs, pero no aísla un proyecto de otro: dentro de
> esa red, las VMs se ven entre sí. Es el riesgo [A-9](seguridad.md#riesgos-aceptados).

**Comprobación:** desde la máquina de un dev con la VPN activa, `make ssh NAME=<vm-de-su-proyecto>`
entra; `curl -k https://<nodo>:8006` y el SSH a una VM de otro proyecto no llegan o se rechazan.
