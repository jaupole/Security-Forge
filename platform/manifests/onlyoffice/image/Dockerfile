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

FROM mirror.gcr.io/onlyoffice/documentserver:9.4.0.1@sha256:3ab6ebc7c605e5a32b7ae3ff19daed4925090245acc8100ce2230bd766c88212

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

# ── Autostart EVERY configured panel plugin ──────────────────────────────────
# Upstream web-apps starts `editorConfig.plugins.autostart` GUIDs ONE AT A TIME
# and only advances to the next when the running plugin CLOSES
# (common/main/lib/controller/Plugins.js: runAutoStartPlugins() shifts one GUID;
# onPluginClose() calls it again). A right-panel plugin never closes by itself,
# so of PF's three autostarted panels only the FIRST ever got its button on the
# right toolbar. This DS autostarts only PF's three panelRight plugins (no modal
# or window plugins), so starting them all is safe: each panel gets its own
# right-toolbar button (toggle group), which is exactly the multi-panel
# behaviour the ONLYOFFICE docs describe for plugins started by hand.
#
# The controller ships as readable source and is loaded by RequireJS at runtime
# (it is NOT inside main/code.js), so the patch is a one-word edit guarded both
# ways: the build FAILS if upstream's text changes, so a base-image bump
# re-surfaces this instead of silently dropping it. nginx serves the
# precompressed sibling (gzip_static on), so it is regenerated.
RUN set -eu; \
    f=/var/www/onlyoffice/documentserver/web-apps/apps/common/main/lib/controller/Plugins.js; \
    test "$(grep -c "if (this.autostart && this.autostart.length > 0) {" "$f")" = 1; \
    test "$(grep -c "this.api.asc_pluginRun(this.autostart.shift(), 0, '');" "$f")" = 1; \
    sed -i "s|if (this.autostart \&\& this.autostart.length > 0) {|while (this.autostart \&\& this.autostart.length > 0) {|" "$f"; \
    test "$(grep -c "while (this.autostart && this.autostart.length > 0) {" "$f")" = 1; \
    gzip -9 -k -f "$f"

# ── Periodic flush of open editing sessions to the app (auto-assembly) ───────
# The editor autosaves into the DS's OWN cache; the file only reaches the app's
# save callback on a manual save, when the last editor closes, or on this
# timer (upstream default: disabled, 5m). With the document as the single
# source of proposal text, a browser crash or logout must not cost more than a
# minute of work, so the DS force-saves every open document once a minute
# (callback status 6, forcesavetype 2). Exports additionally request an
# explicit forcesave before reading the file (PF flushEditorToStorage), so
# this is the floor, not the only guarantee. Set in default.json (always
# loaded; the run script only rewrites local.json) via python3 (in the image;
# jq is not), guarded: the build FAILS if the key is not where upstream puts it.
RUN <<'EOF'
set -eu
c=/etc/onlyoffice/documentserver/default.json
python3 - "$c" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f:
    cfg = json.load(f)
aa = cfg["services"]["CoAuthoring"]["autoAssembly"]
assert aa["enable"] is False and "interval" in aa, aa
aa["enable"] = True
aa["interval"] = "1m"
with open(p, "w") as f:
    json.dump(cfg, f, indent=2)
print("autoAssembly:", cfg["services"]["CoAuthoring"]["autoAssembly"])
PY
grep -q '"interval": "1m"' "$c"
EOF
