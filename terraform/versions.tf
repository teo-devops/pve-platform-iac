# versions.tf — Terraform, provider y su configuracion.
terraform {
  # >= 1.10: version minima con la que se ha probado el bloque cloud {} en modo de
  # ejecucion Local. CI fija la version exacta (TF_VERSION en los workflows).
  required_version = ">= 1.10.0"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # Fijado a la menor. El hash exacto lo fija .terraform.lock.hcl (versionado):
      # un provider distinto del revisado no se instala. Subirlo = PR de Dependabot.
      version = "~> 0.111.0"
    }
  }
}

provider "proxmox" {
  endpoint  = local.platform.proxmox.endpoint
  api_token = var.pm_api_token

  # TLS SIEMPRE verificado (docs/seguridad.md, R-03). El certificado de cada nodo
  # (pve-ssl.pem) lo firma la CA del cluster, que esta versionada en
  # terraform/certs/pve-root-ca.pem. El provider es Go: usa las CA de SSL_CERT_FILE,
  # que los workflows y `make` apuntan a un bundle = CA del sistema + esa CA
  # (scripts/ca-bundle.sh). Sin el bundle el plan falla con
  # "x509: certificate signed by unknown authority": es lo esperado, no lo arregles
  # con insecure = true.
  insecure = false

  # Sin bloque ssh {}: nada de lo que usa este repo necesita SSH a los nodos
  # (la imagen se importa con import_from, por la API). Si un recurso futuro lo
  # pidiera, el provider fallaria al planificar en vez de usar credenciales root.
}
