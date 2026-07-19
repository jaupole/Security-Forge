# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e
#
# Thin SecForge derivative of the upstream ONLYOFFICE Docs (Document Server)
# image. Same Document Server; the Ubuntu base + dependency closure are
# apt-upgraded to current security patches AT BUILD TIME, then scanned and
# cosign-signed. The wrapper exists primarily because the cluster's Kyverno
# restrict-image-registries allowlist has no docker.io/onlyoffice entry —
# ghcr.io/jaupole/* + a keyless signature from this repo's workflow is the
# fleet's approved supply chain (same pattern as gotenberg/keycloak).
#
# UPSTREAM PIN: 9.4.0.1 by digest (9.4 removed the Community Edition
# connection limit). Bump = change both lines below + rebuild via
# .github/workflows/onlyoffice-image-build.yml, then re-pin the digest in
# ../09-deployment.yaml.
#
# mirror.gcr.io = Google's transparent Docker Hub pull-through cache
# (identical bytes — the digest below is the Docker Hub manifest digest — and
# no Hub anonymous pull-rate limit on the self-hosted runner; same dodge as
# the gotenberg Dockerfile).
#
# NOTE: no USER change. The DS runs supervisord as root and drops privileges
# per-service itself; forcing non-root here breaks its init. Root-at-runtime
# is handled at the platform layer (PSS baseline namespace + documented
# Kyverno require-run-as-nonroot exemption).

FROM mirror.gcr.io/onlyoffice/documentserver:9.4.0.1@sha256:e3da62a847b9a5d51a11f73cfea1d9c13c3be3809614490d4edddcf01dcf919b

# Patch the Ubuntu base + dependency closure. Entrypoint/cmd/user are
# inherited from the upstream image.
RUN apt-get update \
 && apt-get upgrade -y \
 && rm -rf /var/lib/apt/lists/*

# ── Proposal Forge built-in editor plugins ───────────────────────────────────
# Bundle PF's two editor-panel plugins into the Document Server's sdkjs-plugins/
# tree. The DS auto-discovers any folder there (services.CoAuthoring.plugins.uri
# = "/sdkjs-plugins") and serves it SAME-ORIGIN — so the editor no longer needs
# the per-session editorConfig.plugins.pluginsData manifest fetch that was
# failing to load these. Each is a self-contained folder: config.json (relative
# url/icons + stable asc.{GUID}) + index.html → plugins.js → code.js, plus
# resources/ and translations/. PF hands each its short-lived per-session token
# at runtime via editorConfig.plugins.options[guid] (read by the plugin from
# Asc.plugin.info.options). Layout + auto-discovery per ONLYOFFICE helpcenter
# "Adding new plugins to server editors" (docs-add-plugin) and
# api.onlyoffice.com plugin on-premises install.
#
# VENDORED COPY: these folders mirror Proposal Forge's
# client/public/plugins/{pf-fields,pf-library,pf-assistant}/ — the DS image build cannot reach
# the PF repo. Source of truth = PF; keep them in sync when the plugin code
# changes there (same GUIDs, same built-in-form config.json).
#
# NOTE on the marketplace store: there is NO DS config key to disable ONLY the
# onlyoffice.github.io plugin marketplace on 9.4 (services.CoAuthoring.plugins
# exposes only uri/autostart/pluginsData; customization.plugins:false would also
# kill THESE built-ins — upstream DocumentServer#2118 is open). PF suppresses it
# per-session via editorConfig.plugins.disable instead. See ../README.md.
COPY plugins/pf-fields/    /var/www/onlyoffice/documentserver/sdkjs-plugins/pf-fields/
COPY plugins/pf-library/   /var/www/onlyoffice/documentserver/sdkjs-plugins/pf-library/
COPY plugins/pf-assistant/ /var/www/onlyoffice/documentserver/sdkjs-plugins/pf-assistant/
