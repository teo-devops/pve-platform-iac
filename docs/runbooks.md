# Runbooks

**Para quién:** el admin, cuando algo va mal. Cada sección dice el **síntoma**, qué hacer y cuál es
el **resultado esperado**. Lo que se haga fuera del pipeline se apunta en el
[registro de break-glass](operador.md#registro-de-break-glass).

| Síntoma | Runbook |
|---|---|
| `drift` falla y abre un issue | [Deriva detectada](#deriva-detectada) |
| «La clave de host … NO coincide» / «HOST IDENTIFICATION HAS CHANGED» | [Clave de host cambiada](#clave-de-host-cambiada) |
| El job `apply` termina en rojo | [Apply fallido](#apply-fallido) |
| `Error acquiring the state lock` | [Estado bloqueado](#estado-bloqueado) |
| Jobs en «Waiting for a runner» | [Runner caído](#runner-caído) |
| Un secreto filtrado o algo inexplicable | [Secreto comprometido](#secreto-comprometido) |
| Una VM ha perdido datos o ha caído un nodo | [Restaurar una VM](#restaurar-una-vm) |

## Deriva detectada

**Síntoma:** el workflow `drift` falla y hay un issue abierto con la etiqueta `drift`.
**Quién:** un admin.
**Resultado esperado:** `drift` lanzado a mano dice «Sin deriva» y el issue queda cerrado.

### 1. Entender qué ha cambiado

Abre el run enlazado en el issue. La tabla dice qué petición tiene cambios; el log del paso «Plan de
deriva» tiene el plan completo (qué atributo difiere y en qué sentido).

| Lo que dice el plan | Qué suele ser |
|---|---|
| `~ update in-place` de una VM (memoria, cores, disco) | Alguien la cambió en la UI de Proxmox |
| `+ create` de una VM que debería existir | La borraron en la UI |
| Cambios en `proxmox_download_file` | Alguien borró o tocó la imagen base en el storage |
| Muchas VMs con el mismo cambio | Una subida del provider que interpreta distinto un atributo; mira los PR recientes de Dependabot |

### 2. Decidir

- **El cambio manual no debía hacerse:** lanza deploy a mano (Actions → deploy → Run workflow). El
  plan revierte Proxmox a lo que dice `main`. Avisa a quien lo hizo.
- **El cambio es correcto y hay que conservarlo:** llévalo a Git. Un PR que deje la petición o el
  catálogo igual que lo que hay en Proxmox. Tras el merge, el plan no tiene cambios.
- **Una VM borrada a mano:** si se quiere recuperar, deploy la recrea **vacía** (desde la imagen). Si
  no, PR que borre su petición.

### 3. Cerrar

Lanza `drift` a mano. Si dice «Sin deriva», cierra el issue con un comentario que diga qué era y qué
se ha hecho.

### Prevenir

Los miembros de los proyectos no tienen usuario en Proxmox: solo los admins pueden cambiar algo en
la UI. Si un admin lo necesita en una emergencia, que lo apunte en el registro de break-glass
([operador.md](operador.md#registro-de-break-glass)).

## Clave de host cambiada

**Síntoma:** el job `known-hosts` de deploy falla con «La clave de host de `<vm>` (`<ip>`) NO coincide
con la publicada y su VM no se ha creado en este deploy», o `make ssh` avisa de «REMOTE HOST
IDENTIFICATION HAS CHANGED».
**Quién:** un admin.
**Resultado esperado:** o se demuestra que es legítimo y se acepta la clave nueva, o se trata como un
incidente.

> [!CAUTION]
> Hasta saber qué pasa, **no entres en esa VM** ni aceptes la clave: si es una suplantación, es
> justo lo que busca el atacante.

### 1. Mirar la clave real en la VM, por un canal que no sea SSH

Consola de Proxmox (noVNC o xterm.js de la VM), con la cuenta `ops` o como root:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Compárala con la que ha leído el pipeline (salida del job `known-hosts`) y con la publicada antes
(`make known-hosts`, columna de la VM).

### 2. Decidir

| La consola dice… | Significa | Qué hacer |
|---|---|---|
| La **misma** clave que la publicada | Quien responde en esa IP **no es la VM**: suplantación o conflicto de IP | Incidente: busca quién tiene esa IP (`ip neigh`, la tabla ARP del router o DHCP). No sigas con el deploy |
| La **nueva** (la que leyó el pipeline) | La VM regeneró sus claves: recreada fuera del pipeline, restaurada de un backup o con cloud-init relanzado | Averigua quién y por qué ([registro de break-glass](operador.md#registro-de-break-glass)); después, acéptala (paso 3) |

### 3. Aceptar la clave nueva (solo si el paso 2 lo justifica)

Actions → deploy → Run workflow → `accept_host_keys`: el nombre de la VM (separa varias con comas).
El deploy publica la clave nueva y desde ahí vuelve a ser estricta.

### 4. Apuntarlo

Una línea en el registro de break-glass: qué VM, qué causa y quién lo ha aceptado.

## Apply fallido

**Síntoma:** el job `apply` de deploy termina en rojo.
**Quién:** un admin.
**Resultado esperado:** un deploy posterior en verde y Proxmox igual que `main`.

Terraform guarda en el estado lo que **sí** ha llegado a crear. Lo normal es arreglar la causa y
relanzar: el plan nuevo solo hace lo que falta.

| Error | Causa | Qué hacer |
|---|---|---|
| `Saved plan is stale` | El estado cambió entre el plan y el apply | Relanza deploy |
| `El plan descifrado (…) no es el que generó el job plan` | El artefacto se ha alterado o se ha mezclado con otro run | **No relances sin investigar**: [Secreto comprometido](#secreto-comprometido) |
| `403 Permission check failed (… VM.Allocate)` u otro privilegio | El token no tiene ACL en el pool del proyecto (¿proyecto nuevo sin `make proxmox-acl`?) | [operador.md: alta de un proyecto](operador.md#alta-de-un-proyecto), paso 2 |
| `x509: certificate signed by unknown authority` | La CA de `terraform/certs/` no es la del cluster, o el endpoint no está en el SAN | [bootstrap.md §3](bootstrap.md#3-ca-del-cluster-proxmox-tls-verificado) |
| `checksum mismatch` en `proxmox_download_file` | La imagen descargada no es la fijada (¿la release cambió? ¿proxy?) | No toques el sha256 a mano: `make image-pin` verifica la firma y saca el bueno |
| `can't lock file … timeout` / `VM is locked` | Una tarea de Proxmox sobre la VM sigue en curso (backup, snapshot) | Espera a que termine (Proxmox → Tasks) y relanza |
| `storage … does not support content type 'import'` | El storage de imágenes no tiene el contenido «import» activado | Datacenter → Storage → (storage) → Content: Import; [D-08](diseno.md#decisiones) |
| Se quedó a medias por un runner muerto | El job se cortó con el lock puesto | [Estado bloqueado](#estado-bloqueado) y relanza |

Si una VM quedó creada pero rota (no arranca o no tiene red), lo más limpio es recrearla: PR que
renombre su fichero de petición (destruir + crear), o break-glass con
`terraform apply -replace='module.standalone_vm["<vm>"].proxmox_virtual_environment_vm.this'`
apuntado en el registro.

## Estado bloqueado

**Síntoma:** un plan o un apply espera 5 minutos y falla con `Error acquiring the state lock`, o
HCP muestra el workspace `pve-platform` como *Locked*.
**Quién:** un admin.
**Resultado esperado:** el workspace queda desbloqueado y el siguiente deploy funciona.

### 1. ¿Hay algo aplicando de verdad?

- Actions → deploy y drift: ¿hay un run **en marcha**? Si lo hay, espera a que termine: el lock es
  legítimo.
- ¿Algún admin está haciendo break-glass (`make apply`)? Pregunta.

### 2. Desbloquear (solo si nada está en marcha)

Lo más habitual: un job cancelado o un runner muerto a mitad de apply. El lock se queda puesto.

- HCP → workspace `pve-platform` → Settings → Locking → **Force unlock** (y apunta el motivo).
- O en local:

  ```sh
  export TF_CLOUD_ORGANIZATION=<HCP_ORG>; read -rs TF_TOKEN_app_terraform_io && export TF_TOKEN_app_terraform_io
  terraform -chdir=terraform init && terraform -chdir=terraform force-unlock <LOCK_ID>
  ```

### 3. Comprobar

Un apply cortado puede haber dejado recursos a medias: lanza deploy a mano. El plan dirá qué falta
y lo completará. Si algo no cuadra: [Apply fallido](#apply-fallido).

HCP guarda versiones del estado (workspace → States): si hubiera que volver a una anterior, se hace
desde ahí, y **solo** sabiendo qué existe de verdad en Proxmox.

## Runner caído

**Síntoma:** jobs de `pr-plan`, `deploy` o `drift` que se quedan en «Waiting for a runner to pick up
this job».
**Quién:** un admin con acceso al host de runners.
**Resultado esperado:** los jobs pendientes arrancan solos.

### 1. ¿Están vivos los supervisores?

```sh
systemctl status 'platform-runner@*'
journalctl -u platform-runner@apply -n 50 --no-pager
docker ps --filter name=platform-
```

| Lo que ves | Causa | Qué hacer |
|---|---|---|
| «No pude pedir la configuración JIT» en bucle | PAT caducado o sin el permiso | Nuevo PAT en `/etc/platform-runner/env` y `systemctl restart 'platform-runner@*'` ([seguridad.md](seguridad.md#pat-de-los-runners)) |
| El servicio no arranca | Docker parado, o la imagen `platform-runner:local` no existe | `systemctl start docker`; reconstruye la imagen ([runner/README.md](../runner/README.md)) |
| Contenedor arrancado pero el job no llega | El grupo de runners no incluye el repo o el workflow | `gh api orgs/<ORG>/actions/runner-groups` ([bootstrap.md §6](bootstrap.md#6-runners-propios)) |
| El job arranca y falla al conectar con Proxmox | Cortafuegos de la red `platform-<tipo>` | [runner/README.md](../runner/README.md), sección de red |

### 2. Si el host entero no vuelve

Los runners son efímeros y no guardan nada: cualquier host nuevo sirve. Sigue
[runner/README.md](../runner/README.md) desde cero y desactiva el host viejo (si alguien pudo
entrar en él, rota el PAT).

### 3. Emergencia mientras tanto

Si hay que aplicar algo urgente con los runners caídos: break-glass
([operador.md](operador.md#break-glass)).

## Secreto comprometido

**Síntoma:** un secreto ha aparecido donde no debía (un log, un chat, un portátil robado), alguien
que no debía ha tenido acceso, o hay algo inexplicable (un plan alterado, VMs que nadie pidió).
**Quién:** un admin. Actúa primero y analiza después.
**Resultado esperado:** la credencial vieja ya no sirve y sabes qué se hizo con ella.

### 1. Cortar (en este orden)

| Secreto | Revocar ya |
|---|---|
| `PM_APPLY_TOKEN` | `pveum user token remove iac@pve apply` en un nodo |
| `PM_PLAN_TOKEN` | `pveum user token remove iac@pve plan` |
| `TF_API_TOKEN` | HCP → owners → Regenerate token |
| `ANSIBLE_SSH_KEY` | PR quitando `service.ci.ssh_key` + deploy, o a mano: quítala de `~ops/.ssh/authorized_keys` en cada VM |
| `PLAN_ENC_KEY` | `openssl rand -base64 48 \| gh secret set PLAN_ENC_KEY --env production` |
| PAT de runners | Revócalo en GitHub y para los supervisores |
| Cuenta de GitHub de un admin | Quítale el acceso al repo (y a `infra-admins` y la organización, en el modelo A) |

Si sospechas del pipeline (plan alterado, workflow cambiado): desactiva los workflows mientras
investigas (`gh workflow disable deploy.yml -R <OWNER>/pve-platform-iac`, y lo mismo con drift y pr-plan).

### 2. Investigar

- Proxmox: Datacenter → Tasks y `/var/log/pve/tasks/`: qué hizo el token y desde qué IP.
- GitHub: Organization → Audit log (secretos leídos, workflows cambiados, miembros añadidos).
- HCP: workspace → States (versiones del estado y quién las escribió).
- `git log -p .github/` desde la fecha sospechosa.
- `drift` a mano: ¿hay cambios en Proxmox que no vienen de Git?

### 3. Reponer

Crea las credenciales nuevas como en [el inventario de secretos](seguridad.md#inventario-de-secretos), vuelve a activar los
workflows y lanza deploy y drift a mano. Apunta el incidente en el registro de break-glass.

## Restaurar una VM

**Síntoma:** una VM ha perdido datos, no arranca o se ha borrado; o ha caído un nodo con sus discos.
**Quién:** un admin.
**Resultado esperado:** la VM vuelve con los datos de la última copia, y el siguiente deploy y
`drift` salen en verde sin recrearla.

Las copias están en Proxmox Backup Server, sobre SeaweedFS
([bootstrap.md §11](bootstrap.md#11-copias-de-seguridad-proxmox-backup-server-sobre-seaweedfs-s3)).
Restaurar es **break-glass**: anótalo en el
[registro](operador.md#registro-de-break-glass).

> [!WARNING]
> Terraform guarda en su estado **en qué nodo** está cada VM. Si la restauras en **otro** nodo, el
> siguiente deploy puede querer recrearla, y la recrearía **vacía**. Restaura siempre en el mismo
> nodo y con el mismo VMID. Si no puedes, sigue el caso C antes de mergear nada.

### A. Recuperar ficheros sueltos

No hace falta restaurar la VM entera: en Proxmox VE, abre el storage `pbs-platform` → Backups →
la copia → **File Restore**, navega por el disco y descarga lo que necesites.

### B. Restaurar la VM entera, en su nodo y con su VMID

1. **Para la VM** si existe, y **avisa** al proyecto: se perderá todo lo hecho desde la última copia.
2. Restaura sobrescribiendo (VM → Backup → la copia → Restore, o por CLI en su nodo):

   ```sh
   pvesm list pbs-platform --vmid <vmid>                       # elige la copia
   qmrestore pbs-platform:backup/vm/<vmid>/<fecha> <vmid> --force 1 --storage <datastore>
   qm start <vmid>
   ```
3. La VM conserva sus claves de host, así que no hace falta tocar `known_hosts`. Si Ansible
   protesta por la clave: [Clave de host cambiada](#clave-de-host-cambiada).
4. Lanza `drift` a mano (Actions → drift → Run workflow). Si la copia era anterior a un cambio de
   tamaño hecho por PR, saldrá deriva. **No la corrijas en la UI**: lanza el deploy de `main` y
   Terraform volverá a dejar la configuración de la VM como dice el repo, sin tocar los datos.
   Después, `configure` vuelve a sincronizar las cuentas de las personas con `projects.yaml`.

### C. El nodo original ya no existe

1. **No cambies `platform.yaml` todavía.** Las VMs se reparten entre los nodos por
   `vmid % número de nodos`: si quitas un nodo, **cambia el nodo de casi todas las VMs**, y Terraform
   querría recrearlas.
2. Restaura las VMs del nodo caído en otro nodo, con el mismo VMID (paso B.2 en el nodo nuevo).
3. Antes de cualquier merge, haz un plan en local (break-glass, [operador.md](operador.md#break-glass))
   y busca `must be replaced` o `destroy`:

   ```sh
   make plan 2>&1 | grep -E 'must be replaced|will be destroyed'
   ```
   Si aparece la VM restaurada, **no apliques**. Saca la VM del estado e impórtala desde su nodo
   nuevo:

   ```sh
   terraform -chdir=terraform state rm 'module.standalone_vm["<vm>"].proxmox_virtual_environment_vm.this'
   terraform -chdir=terraform import 'module.standalone_vm["<vm>"].proxmox_virtual_environment_vm.this' <nodo-nuevo>/<vmid>
   ```
   Si es un nodo de un cluster k3s, la dirección es
   `module.k3s_cluster["<cluster>"].module.vm["<instancia>"].proxmox_virtual_environment_vm.this`;
   cópiala tal cual de la salida del plan. Repite el plan hasta que no proponga recrear nada. Para quitar el nodo de `platform.yaml` de forma
   definitiva, haz un PR aparte y revisa su plan VM a VM.

### Si cae el propio PBS (o el host donde vive)

Las copias siguen en SeaweedFS. Reinstala PBS (en otra máquina si hace falta) y recupera el
datastore con **el mismo nombre**, que es el prefijo de los objetos en el bucket:

```sh
proxmox-backup-manager s3 endpoint create seaweedfs ...           # como en bootstrap §11, paso 3
proxmox-backup-manager datastore create platform /mnt/pbs-cache/platform \
  --backend type=s3,client=seaweedfs,bucket=pbs-platform --reuse-datastore true --overwrite-in-use true
```

Después, vuelve a dar de alta el storage en Proxmox VE con la clave guardada en el gestor de
contraseñas ([seguridad.md](seguridad.md#copias-de-seguridad)).

### Prueba mensual

Una copia que no se ha restaurado nunca no está probada. Una vez al mes, restaura una VM con otro
VMID, fuera de los pools del repo y **sin red**:

```sh
qmrestore pbs-platform:backup/vm/<vmid>/<fecha> 9999 --unique 1 --storage <datastore>
qm set 9999 --delete net0 && qm start 9999        # sin red: no choca con la IP de la original
qm terminal 9999                                   # o la consola en la UI: arranca y los datos están
qm stop 9999 && qm destroy 9999 --purge
```

Apunta en el registro de break-glass la fecha y la VM probada.
