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
