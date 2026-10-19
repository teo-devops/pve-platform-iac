# Puerta de entrada al repo. `make` a secas enseña la ayuda.
#
# Todo lo que no es trivial vive en scripts/iac (Python); esto son solo alias con
# nombres faciles de recordar. Las variables en MAYUSCULAS (NAME, PROJECT, ...) son
# opcionales: sin ellas, el asistente pregunta. Referencia: README.md

IAC := ./scripts/iac
.DEFAULT_GOAL := help
.PHONY: help init setup doctor flavors new-vm new-cluster check list remove plan apply configure \
        ssh kubeconfig known-hosts fmt validate lint docs preflight proxmox-acl image-pin

# Argumentos opcionales -> flags del CLI, solo si se han pasado.
opt = $(if $($(1)),--$(2) "$($(1))")

help: ## Esta ayuda
	@echo "pve-platform-iac — pide VMs y clusters k3s en tu Proxmox VE por PR, sin tocar Terraform"
	@echo
	@echo "PRIMERA VEZ  (docs/peticiones.md)"
	@echo "  make setup                 comprueba lo minimo (python3, PyYAML, ssh)"
	@echo "  make doctor                tu identidad de GitHub, tus proyectos, tus claves y la red"
	@echo
	@echo "PEDIR INFRAESTRUCTURA  (escriben un fichero en requests/ -> commit -> PR desde tu fork)"
	@echo "  make flavors               catalogo de tamaños y perfiles"
	@echo "  make new-vm                asistente: una VM (Ubuntu base o monitorizacion)"
	@echo "  make new-cluster           asistente: un cluster k3s (master + workers repartidos entre nodos)"
	@echo "  make check                 valida requests/ y projects.yaml (sin credenciales)"
	@echo "  make list                  lo pedido; LIVE=1 cruza con lo que ya existe (admin)"
	@echo "  make remove NAME=x         quita una peticion (sus VMs se DESTRUYEN en el deploy)"
	@echo
	@echo "USAR LO CREADO"
	@echo "  make ssh NAME=x            entra en la VM (o en el master del cluster x)"
	@echo "  make kubeconfig NAME=x     trae el kubeconfig del cluster x a ansible/kubeconfigs/"
	@echo "  make known-hosts           claves de host publicadas por el pipeline (SCAN=1: leerlas tu)"
	@echo
	@echo "ADMIN  (docs/operador.md; aplicar en local es break-glass: lo normal es el pipeline)"
	@echo "  make init OWNER=@x         nueva instalacion desde la plantilla (config de examples/)"
	@echo "  make preflight             comprueba la configuracion externa (GitHub, HCP, Proxmox, CA)"
	@echo "  make proxmox-acl           comandos pveum de tokens, pools y ACL (sin nada en /)"
	@echo "  make image-pin [REL=x]     fija la imagen base a una release verificada por GPG"
	@echo "  make plan / make apply     plan y apply en local (break-glass)"
	@echo "  make configure [NAME=x]    Ansible en local (break-glass)"
	@echo "  make lint                  lo mismo que pr-validate: fmt, validate, check, docs"
	@echo "  make docs                  regenera la tabla del catalogo de docs/peticiones.md"

setup: ## Prerrequisitos
	@python3 -c 'import yaml' 2>/dev/null || { echo "✗ Falta PyYAML: sudo apt install python3-yaml"; exit 1; }
	@command -v ssh >/dev/null || { echo "✗ Falta ssh: sudo apt install openssh-client"; exit 1; }
	@ls ~/.ssh/*.pub >/dev/null 2>&1 || echo "! No tienes clave SSH: ssh-keygen -t ed25519, y añade el .pub a tu perfil de GitHub"
	@command -v gh >/dev/null || echo "! Sin gh (https://cli.github.com): lo usan make doctor (tu usuario) y make ssh (claves de host)"
	@echo "✓ Listo. Para pedir infraestructura no necesitas ninguna credencial de infra."
	@echo "  Siguiente: make doctor"

doctor:
	@$(IAC) doctor

flavors:
	@$(IAC) flavors

new-vm:
	@$(IAC) new-vm $(call opt,NAME,name) $(call opt,PROJECT,project) $(call opt,FLAVOR,flavor) \
	  $(call opt,PROFILE,profile)

new-cluster:
	@$(IAC) new-cluster $(call opt,NAME,name) $(call opt,PROJECT,project) $(call opt,SIZE,size) $(call opt,WORKERS,workers)

check:
	@$(IAC) check

list:
	@$(IAC) list $(if $(LIVE),--live)

remove:
	@$(IAC) remove $(NAME)

plan:
	@$(IAC) plan

apply:
	@$(IAC) apply

configure:
	@$(IAC) configure $(call opt,NAME,name) $(call opt,KNOWN_HOSTS,known-hosts) $(ARGS)

ssh:
	@$(IAC) ssh $(NAME)

kubeconfig:
	@$(IAC) kubeconfig $(NAME)

known-hosts:
	@$(IAC) known-hosts $(if $(SCAN),--scan)

fmt:
	terraform -chdir=terraform fmt -recursive

validate:
	terraform -chdir=terraform init -input=false -backend=false >/dev/null
	terraform -chdir=terraform validate

lint: ## Lo mismo que pr-validate, sin docker
	terraform -chdir=terraform fmt -check -recursive
	@$(MAKE) --no-print-directory validate
	@$(IAC) check
	@$(IAC) flavors --check-docs
	@./scripts/check-docs-links.py

docs:
	@$(IAC) flavors --docs

init: ## Nueva instalacion desde la plantilla (OWNER=@usuario o @org/equipo)
	@$(IAC) init $(call opt,OWNER,owner) $(if $(FORCE),--force)

preflight:
	@$(IAC) preflight

proxmox-acl:
	@$(IAC) proxmox-acl

image-pin:
	@./scripts/image-pin.sh $(REL)
