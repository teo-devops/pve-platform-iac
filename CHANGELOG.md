# Changelog

Cambios con impacto para quien usa u opera la plataforma. Formato: fecha, qué y dónde está documentado.

## 15-oct-2026 — Puesta en marcha de Proxmox documentada

- [docs/bootstrap.md](docs/bootstrap.md) §0: preparar Proxmox antes del repo (disco y datastore, repos
  sin suscripción de PVE 9 en formato deb822, ARC de ZFS, bridge con VLAN, DNS, contenido `import`,
  cluster y quórum con dos nodos, cuenta de admin y segundo factor por usuario, copias de seguridad,
  capacidad y exposición).
- §1: transferir el repo si ya existe en una cuenta personal. §10: VPN para que los devs lleguen a
  las VMs.
- VPN de los devs con Cloudflare Zero Trust: túnel `cloudflared` y cliente WARP con login de GitHub
  (D-13, [docs/bootstrap.md §10](docs/bootstrap.md#10-acceso-de-los-devs-a-las-vms-vpn)), y sus
  credenciales en [docs/credenciales.md](docs/credenciales.md#túnel-de-cloudflare).
- [docs/seguridad.md](docs/seguridad.md): riesgo aceptado A-9 (red plana entre proyectos).
- `homelab.yaml`: `image_datastore` necesita el contenido `import` (antes decía «iso», por error).
- Claves SSH del admin y del CI en `projects.yaml`; cómo cambia de PC un admin en
  [docs/operador.md](docs/operador.md#cambio-de-pc-de-un-admin).

## 14-oct-2026 — Primera versión

Plataforma GitOps para el Proxmox del homelab, derivada de `proxmox-iac` (cluster retech de i2cat), que
sigue igual. Decisiones en [docs/diseno.md](docs/diseno.md); comparación con proxmox-iac en
[docs/diseno.md](docs/diseno.md#qué-viene-de-proxmox-iac-y-qué-cambia).

- GitHub Actions con cuatro workflows: `pr-validate`, `pr-plan`, `deploy` y `drift` ([docs/pipeline.md](docs/pipeline.md)).
- Estado en HCP Terraform, con ejecución local (D-03).
- Modelo por proyectos (`projects.yaml`): pool, rangos y miembros; acceso SSH solo a las VMs del
  propio proyecto, con las claves de GitHub (D-10).
- Endurecimiento: dos runners efímeros (D-02, R-08), plan de PR sin código del PR (D-05, R-02), plan
  cifrado y aplicado tal cual (D-06, R-09), TLS verificado (R-03), claves de host estrictas (D-09, R-04),
  imagen fijada y verificada (D-07, R-05), sin SSH a los nodos (D-08, R-06) y tokens sin ACL en `/` (R-07).
- Perfil `dataspace-kind` para los MVP de `teo-devops/dataspace-mvp` (D-11, [docs/dataspace.md](docs/dataspace.md)).
- Imagen base: Ubuntu 24.04 `release-20260926` (sha256 `6a81c375…bb4d2`, firma verificada).
