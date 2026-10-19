# Runners propios

**Para quién:** el admin, al montar o reconstruir el host de runners.
**Qué necesitas antes:** los grupos de runners creados ([docs/bootstrap.md §6](../docs/bootstrap.md#6-runners-propios)),
un host Debian/Ubuntu junto al cluster (LXC privilegiado con nesting, o VM) con Docker, y acceso root.
**Cómo sabrás que ha salido bien:** `systemctl status 'platform-runner@*'` activo, y un PR de prueba
recibe su comentario de `pr-plan`.

## Cómo funciona

`supervisor.sh <tipo>` en bucle: pide a GitHub una configuración **JIT** (un runner de un solo uso,
ya asignado a su grupo y con la etiqueta `platform-plan` o `platform-apply`), arranca un contenedor
nuevo con ella, el contenedor coge **un** job y, al terminar, se destruye
([D-02](../docs/diseno.md#decisiones), [R-08](../docs/seguridad.md#controles)).

```
systemd ─► platform-runner@plan  ─► supervisor.sh plan  ─► docker run (red platform-plan)  ─► 1 job ─► fuera
        └► platform-runner@apply ─► supervisor.sh apply ─► docker run (red platform-apply) ─► 1 job ─► fuera
```

Los contenedores no montan `docker.sock`, no tienen privilegios (`no-new-privileges`) y tienen
límites de memoria y procesos.

## Montarlo

1. **Código e imagen** (como root):

   ```sh
   git clone https://github.com/<ORG>/pve-platform-iac /opt/pve-platform-iac    # o copia la carpeta runner/
   docker build -t platform-runner:local /opt/pve-platform-iac/runner
   ```
2. **PAT** fine-grained: GitHub → Settings → Developer settings → Fine-grained tokens. Con caducidad
   (apúntala) y nada más que esto:
   - **Organización:** *Resource owner* = la organización; permiso de organización **Self-hosted
     runners: Read and write**.
   - **Cuenta personal:** *Resource owner* = tu usuario; *Only select repositories* = este repo;
     permiso de repositorio **Administration: Read and write** (lo exige la API de runners de un
     repo).
3. **Configuración** (`root:root`, `0600`):

   ```sh
   install -d -m 700 /etc/platform-runner
   gh api orgs/<ORG>/actions/runner-groups --jq '.runner_groups[] | "\(.name)=\(.id)"'   # ids de los grupos
   cat > /etc/platform-runner/env <<'EOF'
   GH_ORG=<ORG>
   GH_RUNNER_PAT=github_pat_...
   GROUP_ID_plan=<id de platform-plan>
   GROUP_ID_apply=<id de platform-apply>
   EOF
   chmod 600 /etc/platform-runner/env
   ```
   Con **cuenta personal** no hay grupos de runners: en lugar de `GH_ORG` y `GROUP_ID_*`, pon
   `GH_REPO=<usuario>/pve-platform-iac`. Los runners quedan registrados en el repo.
   Al terminar, activa los jobs que usan runners propios con la variable `PLATFORM_RUNNERS`
   ([bootstrap.md §6](../docs/bootstrap.md#6-runners-propios)).
4. **Redes docker**, una por tipo, para poder filtrarlas por separado:

   ```sh
   docker network create --subnet 172.30.1.0/24 platform-plan
   docker network create --subnet 172.30.2.0/24 platform-apply
   ```
5. **Cortafuegos.** El de `plan` solo necesita la API de Proxmox; el de `apply` también la red de las
   VMs (SSH para Ansible y keyscan). Los dos necesitan Internet (GitHub, HCP, descargas). Ejemplo con
   la cadena `DOCKER-USER` (ajusta las redes: gestión de Proxmox `192.168.1.0/24`, VMs
   `192.168.50.0/24`, resto de la LAN `192.168.0.0/16`):

   ```sh
   # plan: Proxmox :8006 si; el resto de la LAN, no
   iptables -I DOCKER-USER -s 172.30.1.0/24 -d 192.168.0.0/16 -j DROP
   iptables -I DOCKER-USER -s 172.30.1.0/24 -d 192.168.1.0/24 -p tcp --dport 8006 -j ACCEPT
   # apply: Proxmox :8006 y las VMs (:22); el resto de la LAN, no
   iptables -I DOCKER-USER -s 172.30.2.0/24 -d 192.168.0.0/16 -j DROP
   iptables -I DOCKER-USER -s 172.30.2.0/24 -d 192.168.50.0/24 -p tcp --dport 22 -j ACCEPT
   iptables -I DOCKER-USER -s 172.30.2.0/24 -d 192.168.1.0/24 -p tcp --dport 8006 -j ACCEPT
   # respuestas
   iptables -I DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
   apt install iptables-persistent && netfilter-persistent save
   ```
   Si el DNS de los contenedores es un servidor de la LAN, permítelo también (`-p udp --dport 53`).
   Compruébalo desde un contenedor de cada red: Proxmox responde y una IP cualquiera de la LAN no.
6. **Servicios:**

   ```sh
   cp /opt/pve-platform-iac/runner/platform-runner@.service /etc/systemd/system/
   systemctl daemon-reload
   systemctl enable --now platform-runner@plan platform-runner@apply
   journalctl -fu platform-runner@plan      # "... esperando un job"
   ```

## Mantenerlo

- **Imagen:** Dependabot propone las versiones nuevas de `actions-runner` en `runner/Dockerfile`. Tras
  el merge: `git -C /opt/pve-platform-iac pull && docker build -t platform-runner:local /opt/pve-platform-iac/runner`.
  No hace falta reiniciar: cada job nuevo usa la imagen nueva.
- **PAT:** antes de que caduque ([seguridad.md](../docs/seguridad.md#pat-de-los-runners)).
- **Acceso al host:** solo admins. Quien entra en este host puede leer el PAT y ver los jobs en
  marcha ([A-5](../docs/seguridad.md#riesgos-aceptados)).
- **Problemas:** [docs/runbooks.md](../docs/runbooks.md#runner-caído).

## Ficheros

| Fichero | Qué es |
|---|---|
| `Dockerfile` | Imagen oficial `actions-runner` fijada + python3-yaml, ansible, gnupg, jq, gh… |
| `supervisor.sh` | Bucle JIT → contenedor efímero |
| `platform-runner@.service` | Unidad systemd, una instancia por tipo |
