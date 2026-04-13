#!/bin/bash
# Refresh the Artifact Registry OAuth2 access token baked into
# /root/.docker/config.json.
#
# Nomad's Docker plugin reads this file for pull auth. The token from
# `gcloud auth print-access-token` expires every hour, so this script
# is installed on the Nomad VM and run from root's crontab every 30
# minutes:
#
#   */30 * * * * /usr/local/sbin/refresh-ar-docker-auth.sh \
#       >> /var/log/refresh-ar-docker-auth.log 2>&1
#
# The credHelpers block is kept as a fallback for any caller (docker
# CLI, etc.) that honors it — the Nomad plugin does not.
set -euo pipefail

TOKEN=$(/usr/bin/gcloud auth print-access-token)
AUTH=$(printf "oauth2accesstoken:%s" "$TOKEN" | base64 -w0)

TMP=$(mktemp)
trap "rm -f $TMP" EXIT
cat > "$TMP" <<EOF
{
  "auths": {
    "us-central1-docker.pkg.dev": {
      "auth": "$AUTH"
    }
  },
  "credHelpers": {
    "us-central1-docker.pkg.dev": "gcloud"
  }
}
EOF
install -o root -g root -m 0600 "$TMP" /root/.docker/config.json
echo "$(date -Iseconds) refreshed AR token"
