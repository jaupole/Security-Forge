#!/usr/bin/env bash
# RETIRED — the local-edition Wazuh deploy path was retired during the
# bare-metal migration. This script is intentionally inert.
#
# Why this is a guard and not just deleted: running the old script would
# `helm upgrade` the `wazuh` release from the stale local-edition vendored
# chart, silently reverting the live reconciled release.
#
# Deploy / re-deploy / rotate Wazuh credentials via the platform path:
#   bash platform/components/07-wazuh.sh
#
#   chart:   platform/manifests/wazuh/vendor-chart/
#   values:  platform/values/wazuh.yaml
#   runbook: docs/03-runbooks/wazuh-operations.md
set -euo pipefail
echo "infrastructure/wazuh/apply.sh is RETIRED — do not deploy from here." >&2
echo "Use:  bash platform/components/07-wazuh.sh" >&2
exit 1
