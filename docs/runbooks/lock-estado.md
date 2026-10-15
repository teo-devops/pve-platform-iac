# Runbook: estado de Terraform bloqueado

**Síntoma:** un plan o un apply espera 5 minutos y falla con `Error acquiring the state lock`, o
HCP muestra el workspace `homelab` como *Locked*.
**Quién:** un admin.
**Resultado esperado:** el workspace queda desbloqueado y el siguiente deploy funciona.

## 1. ¿Hay algo aplicando de verdad?

- Actions → deploy y drift: ¿hay un run **en marcha**? Si lo hay, espera a que termine: el lock es
  legítimo.
- ¿Algún admin está haciendo break-glass (`make apply`)? Pregunta.

## 2. Desbloquear (solo si nada está en marcha)

Lo más habitual: un job cancelado o un runner muerto a mitad de apply. El lock se queda puesto.

- HCP → workspace `homelab` → Settings → Locking → **Force unlock** (y apunta el motivo).
- O en local:

  ```sh
  export TF_CLOUD_ORGANIZATION=<HCP_ORG>; read -rs TF_TOKEN_app_terraform_io && export TF_TOKEN_app_terraform_io
  terraform -chdir=terraform init && terraform -chdir=terraform force-unlock <LOCK_ID>
  ```

## 3. Comprobar

Un apply cortado puede haber dejado recursos a medias: lanza deploy a mano. El plan dirá qué falta
y lo completará. Si algo no cuadra: [apply-fallido.md](apply-fallido.md).

HCP guarda versiones del estado (workspace → States): si hubiera que volver a una anterior, se hace
desde ahí, y **solo** sabiendo qué existe de verdad en Proxmox.
