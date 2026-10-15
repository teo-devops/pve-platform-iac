# Imagen de los runners de la plataforma (platform-plan y platform-apply).
#
# Base oficial de GitHub, version fijada (Dependabot la sube por PR). Encima, SOLO
# las herramientas que usan los workflows; Terraform lo instala cada job con
# hashicorp/setup-terraform en la version fijada en el workflow.
#
# Construir en el host de runners:  docker build -t platform-runner:local runner/
FROM ghcr.io/actions/actions-runner:2.338.0

USER root
# python3-yaml: scripts/iac · ansible: configure · gnupg: plan cifrado · jq, unzip:
# known-hosts · openssh-client: ssh-keyscan y Ansible · curl: preflight
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-yaml python3-pip python3-venv ansible jq unzip gnupg openssh-client curl ca-certificates git \
 && rm -rf /var/lib/apt/lists/*
# gh: known-hosts baja el artefacto del deploy anterior con la API
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh && rm -rf /var/lib/apt/lists/*
USER runner
