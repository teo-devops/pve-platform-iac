# Runbook: apply fallido

**Síntoma:** el job `apply` de deploy termina en rojo.
**Quién:** un admin.
**Resultado esperado:** un deploy posterior en verde y Proxmox igual que `main`.

Terraform guarda en el estado lo que **sí** ha llegado a crear. Lo normal es arreglar la causa y
relanzar: el plan nuevo solo hace lo que falta.

| Error | Causa | Qué hacer |
|---|---|---|
| `Saved plan is stale` | El estado cambió entre el plan y el apply | Relanza deploy |
| `El plan descifrado (…) no es el que generó el job plan` | El artefacto se ha alterado o se ha mezclado con otro run | **No relances sin investigar**: [token-comprometido.md](token-comprometido.md) |
| `403 Permission check failed (… VM.Allocate)` u otro privilegio | El token no tiene ACL en el pool del proyecto (¿proyecto nuevo sin `make proxmox-acl`?) | [operador.md: alta de un proyecto](../operador.md#alta-de-un-proyecto), paso 2 |
| `x509: certificate signed by unknown authority` | La CA de `terraform/certs/` no es la del cluster, o el endpoint no está en el SAN | [bootstrap.md §3](../bootstrap.md#3-ca-del-cluster-proxmox-tls-verificado) |
| `checksum mismatch` en `proxmox_download_file` | La imagen descargada no es la fijada (¿la release cambió? ¿proxy?) | No toques el sha256 a mano: `make image-pin` verifica la firma y saca el bueno |
| `can't lock file … timeout` / `VM is locked` | Una tarea de Proxmox sobre la VM sigue en curso (backup, snapshot) | Espera a que termine (Proxmox → Tasks) y relanza |
| `storage … does not support content type 'import'` | El storage de imágenes no tiene el contenido «import» activado | Datacenter → Storage → (storage) → Content: Import; [D-08](../diseno.md#decisiones) |
| Se quedó a medias por un runner muerto | El job se cortó con el lock puesto | [lock-estado.md](lock-estado.md) y relanza |

Si una VM quedó creada pero rota (no arranca o no tiene red), lo más limpio es recrearla: PR que
renombre su fichero de petición (destruir + crear), o break-glass con
`terraform apply -replace='module.standalone_vm["<vm>"].proxmox_virtual_environment_vm.this'`
apuntado en el registro.
