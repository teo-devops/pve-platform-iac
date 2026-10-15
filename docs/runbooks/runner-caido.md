# Runbook: runner caído

**Síntoma:** jobs de `pr-plan`, `deploy` o `drift` que se quedan en «Waiting for a runner to pick up
this job».
**Quién:** un admin con acceso al host de runners.
**Resultado esperado:** los jobs pendientes arrancan solos.

## 1. ¿Están vivos los supervisores?

```sh
systemctl status 'platform-runner@*'
journalctl -u platform-runner@apply -n 50 --no-pager
docker ps --filter name=platform-
```

| Lo que ves | Causa | Qué hacer |
|---|---|---|
| «No pude pedir la configuración JIT» en bucle | PAT caducado o sin el permiso | Nuevo PAT en `/etc/platform-runner/env` y `systemctl restart 'platform-runner@*'` ([credenciales.md](../credenciales.md#pat-de-los-runners)) |
| El servicio no arranca | Docker parado, o la imagen `platform-runner:local` no existe | `systemctl start docker`; reconstruye la imagen ([runner/README.md](../../runner/README.md)) |
| Contenedor arrancado pero el job no llega | El grupo de runners no incluye el repo o el workflow | `gh api orgs/<ORG>/actions/runner-groups` ([bootstrap.md §6](../bootstrap.md#6-runners-propios)) |
| El job arranca y falla al conectar con Proxmox | Cortafuegos de la red `platform-<tipo>` | [runner/README.md](../../runner/README.md), sección de red |

## 2. Si el host entero no vuelve

Los runners son efímeros y no guardan nada: cualquier host nuevo sirve. Sigue
[runner/README.md](../../runner/README.md) desde cero y desactiva el host viejo (si alguien pudo
entrar en él, rota el PAT).

## 3. Emergencia mientras tanto

Si hay que aplicar algo urgente con los runners caídos: break-glass
([operador.md](../operador.md#break-glass)).
