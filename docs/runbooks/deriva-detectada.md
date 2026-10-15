# Runbook: deriva detectada

**Síntoma:** el workflow `drift` falla y hay un issue abierto con la etiqueta `drift`.
**Quién:** un admin.
**Resultado esperado:** `drift` lanzado a mano dice «Sin deriva» y el issue queda cerrado.

## 1. Entender qué ha cambiado

Abre el run enlazado en el issue. La tabla dice qué petición tiene cambios; el log del paso «Plan de
deriva» tiene el plan completo (qué atributo difiere y en qué sentido).

| Lo que dice el plan | Qué suele ser |
|---|---|
| `~ update in-place` de una VM (memoria, cores, disco) | Alguien la cambió en la UI de Proxmox |
| `+ create` de una VM que debería existir | La borraron en la UI |
| Cambios en `proxmox_download_file` | Alguien borró o tocó la imagen base en el storage |
| Muchas VMs con el mismo cambio | Una subida del provider que interpreta distinto un atributo; mira los PR recientes de Dependabot |

## 2. Decidir

- **El cambio manual no debía hacerse:** lanza deploy a mano (Actions → deploy → Run workflow). El
  plan revierte Proxmox a lo que dice `main`. Avisa a quien lo hizo.
- **El cambio es correcto y hay que conservarlo:** llévalo a Git. Un PR que deje la petición o el
  catálogo igual que lo que hay en Proxmox. Tras el merge, el plan no tiene cambios.
- **Una VM borrada a mano:** si se quiere recuperar, deploy la recrea **vacía** (desde la imagen). Si
  no, PR que borre su petición.

## 3. Cerrar

Lanza `drift` a mano. Si dice «Sin deriva», cierra el issue con un comentario que diga qué era y qué
se ha hecho.

## Prevenir

Los miembros de los proyectos no tienen usuario en Proxmox: solo los admins pueden cambiar algo en
la UI. Si un admin lo necesita en una emergencia, que lo apunte en el registro de break-glass
([operador.md](../operador.md#registro-de-break-glass)).
