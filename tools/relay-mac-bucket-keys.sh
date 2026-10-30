#!/bin/bash
# Puts upload keys for Relay's update bucket (macos-releases on Yandex Object Storage, where Snippets also publishes)
# into ~/.relay-secrets/macos-release.env, then publishes the release already built (tools/relay-mac-publish.sh).
#
# By default through the Yandex Cloud CLI (installed into ~/yandex-cloud when missing, shell profile untouched;
# `yc init` logs in with a token from a browser page): finds the folder that holds the bucket, makes a service account
# relay-mac-releases there with storage.uploader on the folder (upload and overwrite, no delete) and creates a static
# access key for it. The secret goes straight into the file and is never printed.
# --paste asks for an existing key pair instead (Snippets' Distribution/.env has one).
#
# Interactive: run it in a terminal.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${RELAY_RELEASE_ENV:-$HOME/.relay-secrets/macos-release.env}"
BUCKET=macos-releases
SA_NAME=relay-mac-releases

jget() {
    python3 -I -c "import json, sys; d = json.load(sys.stdin); print($1)"
}

# Writes RELAY_KEY_ID and RELAY_SECRET (from the environment, never argv) into ENV_FILE, keeping its other lines.
write_keys() {
    mkdir -p "$(dirname "$ENV_FILE")"
    chmod 700 "$(dirname "$ENV_FILE")"
    python3 -I - "$ENV_FILE" <<'PY'
import os, sys
path = sys.argv[1]
values = {"AWS_ACCESS_KEY_ID": os.environ["RELAY_KEY_ID"], "AWS_SECRET_ACCESS_KEY": os.environ["RELAY_SECRET"]}
defaults = {"S3_BUCKET": "macos-releases", "S3_ENDPOINT": "https://storage.yandexcloud.net", "S3_REGION": "ru-central1", "S3_PREFIX": "relay"}
lines = open(path).read().splitlines() if os.path.exists(path) else []
seen, out = set(), []
for line in lines:
    key = line.split("=", 1)[0].strip() if "=" in line and not line.lstrip().startswith("#") else None
    if key:
        seen.add(key)
    out.append(f"{key}={values[key]}" if key in values else line)
for key, value in {**defaults, **values}.items():
    if key not in seen:
        out.append(f"{key}={value}")
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write("\n".join(out) + "\n")
os.chmod(path, 0o600)
PY
}

if [ "${1:-}" = "--paste" ]; then
    echo "A key pair for the bucket $BUCKET: Snippets' Distribution/.env (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY),"
    echo "or a new static access key: console.yandex.cloud -> the folder with the bucket -> Service accounts -> Create"
    echo "(name $SA_NAME, role storage.uploader) -> open it -> Create new key -> Static access key."
    read -r -p "AWS_ACCESS_KEY_ID (key ID): " RELAY_KEY_ID
    read -r -s -p "AWS_SECRET_ACCESS_KEY (secret key, not shown): " RELAY_SECRET
    echo
    [ -n "$RELAY_KEY_ID" ] && [ -n "$RELAY_SECRET" ] || { echo "both are needed"; exit 1; }
else
    YC="$(command -v yc || true)"
    [ -n "$YC" ] || YC="$HOME/yandex-cloud/bin/yc"
    if [ ! -x "$YC" ]; then
        echo "== installing the Yandex Cloud CLI into ~/yandex-cloud"
        INSTALLER_DIR="$(mktemp -d)"
        curl -sSfL -o "$INSTALLER_DIR/install.sh" https://storage.yandexcloud.net/yandexcloud-yc/install.sh
        bash "$INSTALLER_DIR/install.sh" -i "$HOME/yandex-cloud" -n
    fi
    # `yc init` logs in through the browser, which must come back to 127.0.0.1. An OAuth token is no way around it:
    # Yandex Cloud refuses OAuth tokens issued after 2026-06-01 ("not supported for IAM token exchange"), and
    # `yc config set token` puts the token into the name of its log file.
    if ! "$YC" iam create-token >/dev/null 2>&1; then
        echo "== yc init: Enter opens the browser; log in with the Yandex account whose cloud holds $BUCKET"
        "$YC" init || true
        if ! "$YC" iam create-token >/dev/null 2>&1; then
            echo "Not logged in to Yandex Cloud. Make the key in the console instead and run this with --paste:"
            echo "  console.yandex.cloud -> the folder with the bucket $BUCKET -> Service accounts -> Create:"
            echo "  name $SA_NAME, role storage.uploader -> open it -> Create new key -> Static access key"
            exit 1
        fi
    fi

    echo "== looking for the bucket $BUCKET"
    FOLDER="$("$YC" storage bucket get "$BUCKET" --format json 2>/dev/null | jget 'd["folder_id"]' || true)"
    if [ -z "$FOLDER" ]; then
        for cloud in $("$YC" resource-manager cloud list --format json | jget '"\n".join(c["id"] for c in d)'); do
            for folder in $("$YC" resource-manager folder list --cloud-id "$cloud" --format json | jget '"\n".join(f["id"] for f in d)'); do
                if [ "$("$YC" storage bucket list --folder-id "$folder" --format json 2>/dev/null | jget "any(b['name'] == '$BUCKET' for b in d)" || true)" = "True" ]; then
                    FOLDER="$folder"
                    break 2
                fi
            done
        done
    fi
    [ -n "$FOLDER" ] || { echo "no folder this Yandex account can see holds the bucket $BUCKET"; exit 1; }

    echo "The bucket $BUCKET is in folder $FOLDER. This makes (or reuses) the service account $SA_NAME there,"
    echo "gives it storage.uploader on that folder and creates a new static access key for it."
    read -r -p "Go on? [y/N] " answer
    case "$answer" in y|Y|yes|д|Д|да) ;; *) echo "nothing changed"; exit 1 ;; esac

    SA_ID="$("$YC" iam service-account get --name "$SA_NAME" --folder-id "$FOLDER" --format json 2>/dev/null | jget 'd["id"]' || true)"
    if [ -z "$SA_ID" ]; then
        SA_ID="$("$YC" iam service-account create --name "$SA_NAME" --folder-id "$FOLDER" \
            --description "Uploads Relay for macOS releases (wowlocal/relay-mac)" --format json | jget 'd["id"]')"
        echo "made service account $SA_NAME"
    fi
    if ! BINDING="$("$YC" resource-manager folder add-access-binding "$FOLDER" --role storage.uploader --subject "serviceAccount:$SA_ID" 2>&1)"; then
        case "$BINDING" in *"already"*) ;; *) echo "$BINDING"; exit 1 ;; esac
    fi
    KEY_JSON="$("$YC" iam access-key create --service-account-id "$SA_ID" --description "relay-mac releases from $(hostname -s)" --format json)"
    RELAY_KEY_ID="$(printf '%s' "$KEY_JSON" | jget 'd["access_key"]["key_id"]')"
    RELAY_SECRET="$(printf '%s' "$KEY_JSON" | jget 'd["secret"]')"
    unset KEY_JSON
fi

export RELAY_KEY_ID RELAY_SECRET
write_keys
unset RELAY_KEY_ID RELAY_SECRET
echo "keys saved in $ENV_FILE"

echo "== publishing (a new role can take a minute to apply)"
for attempt in 1 2 3 4; do
    if bash tools/relay-mac-publish.sh; then
        exit 0
    fi
    [ "$attempt" = 4 ] && exit 1
    echo "retrying in 30 s"
    sleep 30
done
