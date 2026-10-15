# Runbook: restaurar una VM desde una copia

**Síntoma:** una VM ha perdido datos, no arranca o se ha borrado; o ha caído un nodo con sus discos.
**Quién:** un admin.
**Resultado esperado:** la VM vuelve con los datos de la última copia, y el siguiente deploy y
`drift` salen en verde sin recrearla.

Las copias están en Proxmox Backup Server, sobre SeaweedFS
([bootstrap.md §11](../bootstrap.md#11-copias-de-seguridad-proxmox-backup-server-sobre-seaweedfs-s3)).
Restaurar es **break-glass**: anótalo en el
[registro](../operador.md#registro-de-break-glass).

> [!WARNING]
> Terraform guarda en su estado **en qué nodo** está cada VM. Si la restauras en **otro** nodo, el
> siguiente deploy puede querer recrearla, y la recrearía **vacía**. Restaura siempre en el mismo
> nodo y con el mismo VMID. Si no puedes, sigue el caso C antes de mergear nada.

## A. Recuperar ficheros sueltos

No hace falta restaurar la VM entera: en Proxmox VE, abre el storage `pbs-homelab` → Backups →
la copia → **File Restore**, navega por el disco y descarga lo que necesites.

## B. Restaurar la VM entera, en su nodo y con su VMID

1. **Para la VM** si existe, y **avisa** al proyecto: se perderá todo lo hecho desde la última copia.
2. Restaura sobrescribiendo (VM → Backup → la copia → Restore, o por CLI en su nodo):

   ```sh
   pvesm list pbs-homelab --vmid <vmid>                       # elige la copia
   qmrestore pbs-homelab:backup/vm/<vmid>/<fecha> <vmid> --force 1 --storage <datastore>
   qm start <vmid>
   ```
3. La VM conserva sus claves de host, así que no hace falta tocar `known_hosts`. Si Ansible
   protesta por la clave: [clave-de-host-cambiada.md](clave-de-host-cambiada.md).
4. Lanza `drift` a mano (Actions → drift → Run workflow). Si la copia era anterior a un cambio de
   tamaño hecho por PR, saldrá deriva. **No la corrijas en la UI**: lanza el deploy de `main` y
   Terraform volverá a dejar la configuración de la VM como dice el repo, sin tocar los datos.
   Después, `configure` vuelve a sincronizar las cuentas de las personas con `projects.yaml`.

## C. El nodo original ya no existe

1. **No cambies `homelab.yaml` todavía.** Las VMs se reparten entre los nodos por
   `vmid % número de nodos`: si quitas un nodo, **cambia el nodo de casi todas las VMs**, y Terraform
   querría recrearlas.
2. Restaura las VMs del nodo caído en otro nodo, con el mismo VMID (paso B.2 en el nodo nuevo).
3. Antes de cualquier merge, haz un plan en local (break-glass, [operador.md](../operador.md#break-glass))
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
   cópiala tal cual de la salida del plan. Repite el plan hasta que no proponga recrear nada. Para quitar el nodo de `homelab.yaml` de forma
   definitiva, haz un PR aparte y revisa su plan VM a VM.

## Si cae el propio PBS (o el host donde vive)

Las copias siguen en SeaweedFS. Reinstala PBS (en otra máquina si hace falta) y recupera el
datastore con **el mismo nombre**, que es el prefijo de los objetos en el bucket:

```sh
proxmox-backup-manager s3 endpoint create seaweedfs ...           # como en bootstrap §11, paso 3
proxmox-backup-manager datastore create homelab /mnt/pbs-cache/homelab \
  --backend type=s3,client=seaweedfs,bucket=pbs-homelab --reuse-datastore true --overwrite-in-use true
```

Después, vuelve a dar de alta el storage en Proxmox VE con la clave guardada en el gestor de
contraseñas ([credenciales.md](../credenciales.md#copias-de-seguridad)).

## Prueba mensual

Una copia que no se ha restaurado nunca no está probada. Una vez al mes, restaura una VM con otro
VMID, fuera de los pools del repo y **sin red**:

```sh
qmrestore pbs-homelab:backup/vm/<vmid>/<fecha> 9999 --unique 1 --storage <datastore>
qm set 9999 --delete net0 && qm start 9999        # sin red: no choca con la IP de la original
qm terminal 9999                                   # o la consola en la UI: arranca y los datos están
qm stop 9999 && qm destroy 9999 --purge
```

Apunta en el registro de break-glass la fecha y la VM probada.
