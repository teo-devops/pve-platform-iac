# Changelog

Cambios con impacto para quien usa u opera la plataforma. Formato: fecha, qué y dónde está documentado.

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
