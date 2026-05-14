#!/usr/bin/env bash
# 08 — Teleport (privileged access)
#
# Depends on: 03-keycloak (or GitHub OAuth — per ADR-0024 amendment, CE has no OIDC),
#             07-observability (forwards audit events; deferred per Phase 7d follow-ups)
#
# Will install:
#   - Teleport CE (community edition) StatefulSet
#   - GitHub OAuth connector (org `security-forge1`, team `platform-admins` -> admin role)
#   - Helm values: proxy_listener_mode = multiplex (default `separate` breaks tsh CLI on this setup)
#   - MinIO bucket binding for session recordings
#   - Ingress: tp.${DOMAIN}
#
# Once Teleport is up, it becomes the kubectl-access path. We then restrict 6443/tcp
# in ufw to localhost-only (k3s API) and route all admin kubectl through Teleport's
# k8s proxy. This closes the "open k8s API to the world" UFW rule.
#
# Reference: infrastructure/teleport (if exists) + ADR-0024 + docs/03-runbooks/teleport-operations.md
#            Production changes:
#              - proxy URL: https://tp.${DOMAIN}
#              - admin role currently system:masters — scope down at cloud cutover (per ADR-0024)

set -euo pipefail
echo "TODO: 08-teleport.sh not yet implemented" >&2
echo "  After this component is up, also tighten ufw to restrict :6443 to localhost." >&2
exit 1
