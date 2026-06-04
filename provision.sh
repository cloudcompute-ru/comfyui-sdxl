#!/usr/bin/env bash
#
# Tutorial provision script for "SDXL в ComfyUI" (RealVisXL V5.0).
#
# Runs on the GPU instance after the container starts. The customer app's
# onstart wrapper exports two env vars before invoking us:
#
#   CC_PROVISION_URL   POST endpoint for stage updates
#                      (e.g. https://app.cloudcompute.ru/api/agent/provision)
#   CC_AGENT_TOKEN     bearer token authenticating us to that endpoint
#
# Both are optional — if absent, report_stage is a silent no-op so the
# script still works for local manual testing (e.g. via `bash provision.sh`
# inside a fresh container).
#
# Stage IDs reported here MUST match the customer app's
# config/applications.php provisioning.stages entries for `comfyui-sdxl`.
# Anything else is fine to log to stdout but won't drive the UI.
#
# stdout/stderr go to /var/log/cc-provision.log (the onstart wrapper sets
# this up via `nohup ... > /var/log/cc-provision.log 2>&1 &`).

set -euo pipefail

CC_PROVISION_URL="${CC_PROVISION_URL:-}"
CC_AGENT_TOKEN="${CC_AGENT_TOKEN:-}"
COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
MODEL_DIR="${COMFYUI_DIR}/models/checkpoints"
MODEL_FILE="${MODEL_DIR}/RealVisXL_V5.0_fp16.safetensors"
WORKFLOW_DIR="${COMFYUI_DIR}/user/default/workflows"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"

# Where to fetch heavy assets (model weights) from.
#
# Resolution order, highest precedence first:
#   1. YANDEX_MIRROR_URL  — explicit full URL override (set this for ad-hoc
#                            testing against a staging file or a HuggingFace
#                            mirror; wins outright when set)
#   2. CC_TUTORIAL_MIRROR_URL — base URL of the customer app's configured
#                            tutorials_mirror S3 bucket, exported by the
#                            onstart wrapper. This is the production path:
#                            the customer app always knows the correct
#                            bucket because it generates URLs from the same
#                            Storage::disk('tutorials_mirror') config used
#                            elsewhere, so bucket renames can't break us.
#   3. Hardcoded base URL — last-resort fallback for the local-test case
#                            of running `bash provision.sh` inside a fresh
#                            container with no customer-app env at all.
#                            Must point at a real, currently-correct bucket
#                            so manual tests succeed without env setup.
CC_TUTORIAL_MIRROR_URL="${CC_TUTORIAL_MIRROR_URL:-https://storage.yandexcloud.net/cc-tutorials}"
YANDEX_MIRROR_URL="${YANDEX_MIRROR_URL:-${CC_TUTORIAL_MIRROR_URL%/}/tutorials/comfyui-sdxl/RealVisXL_V5.0_fp16.safetensors}"

# Default workflow shipped alongside this script. The onstart wrapper only
# fetches provision.sh, so we re-fetch workflow.json from this same repo at
# the same ref. CC_WORKFLOW_REF lets a pinned rollout override `main`.
CC_WORKFLOW_REF="${CC_WORKFLOW_REF:-main}"
WORKFLOW_URL="${WORKFLOW_URL:-https://raw.githubusercontent.com/cloudcompute-ru/comfyui-sdxl/${CC_WORKFLOW_REF}/workflow.json}"

# --- helpers --------------------------------------------------------------

# report_stage <json-payload>
#
# Best-effort POST to /api/agent/provision. Failures (network blips, 401,
# 422 from misconstructed payloads) are swallowed: a missed update is far
# preferable to crashing provisioning halfway through. The frontend's HTTP
# poll on the entrypoint port is the ultimate ready gate, so even if every
# single report_stage call fails the user still gets a working session.
report_stage() {
    if [ -z "$CC_PROVISION_URL" ] || [ -z "$CC_AGENT_TOKEN" ]; then
        return 0
    fi
    curl -fsS \
        -X POST "$CC_PROVISION_URL" \
        -H "Authorization: Bearer $CC_AGENT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$1" \
        --max-time 5 \
        >/dev/null 2>&1 || true
}

log() {
    echo "[cc-provision] $*"
}

# --- stage 1: install_comfyui --------------------------------------------

log "stage: install_comfyui"
report_stage '{"stage":"install_comfyui"}'

mkdir -p /workspace
if [ ! -d "$COMFYUI_DIR/.git" ]; then
    git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
fi
cd "$COMFYUI_DIR"
pip install --no-cache-dir -r requirements.txt

# ComfyUI Manager: in-UI installer for custom nodes and missing models.
# Without this preinstalled, the first workflow a user opens that needs a
# custom node hits them with a cryptic "first run `pip install ... comfyui-
# manager` then restart with --enable-manager" wall — which is impossible
# for a tutorial user because they don't have terminal access to the
# container by default. Install + enable up-front so the in-UI manager is
# always available. --pre matches ComfyUI's own install instructions (the
# pip distribution is currently a pre-release).
pip install --no-cache-dir -U --pre comfyui-manager

mkdir -p "$MODEL_DIR" "$WORKFLOW_DIR"

# --- stage 2: download_model ---------------------------------------------

log "stage: download_model"
report_stage '{"stage":"download_model","progress_pct":0}'

if [ -f "$MODEL_FILE" ] && [ "$(stat -c%s "$MODEL_FILE" 2>/dev/null || echo 0)" -gt 1000000000 ]; then
    log "model already present, skipping download"
    report_stage '{"stage":"download_model","progress_pct":100}'
else
    # wget --progress=dot:giga prints lines like
    #   "  100M ........ ........ ........ ........ ........ ........ 12% 45.6M 14m"
    # We grep the percentage out and forward it as a coarse progress signal.
    # Even if parsing misses every line, the stage label is the primary
    # signal — `with_progress` is just a UX nicety.
    last_reported=-1
    set +e
    wget \
        --tries=3 \
        --timeout=120 \
        --progress=dot:giga \
        -O "${MODEL_FILE}.partial" \
        "$YANDEX_MIRROR_URL" 2>&1 | \
    while IFS= read -r line; do
        echo "$line"
        pct=$(echo "$line" | grep -oE '[0-9]+%' | tail -1 | tr -d '%' || true)
        if [ -n "$pct" ] && [ "$pct" -ne "$last_reported" ] 2>/dev/null; then
            # Throttle: only forward 0/10/20/.../100 to avoid hammering the API.
            mod=$((pct % 10))
            if [ "$mod" -eq 0 ] || [ "$pct" -ge 99 ]; then
                report_stage "{\"stage\":\"download_model\",\"progress_pct\":${pct}}"
                last_reported=$pct
            fi
        fi
    done
    wget_status=${PIPESTATUS[0]}
    set -e

    if [ "$wget_status" -ne 0 ]; then
        log "wget failed with exit $wget_status"
        report_stage "{\"stage\":\"download_model\",\"message\":\"wget failed: exit ${wget_status}\"}"
        exit "$wget_status"
    fi

    mv "${MODEL_FILE}.partial" "$MODEL_FILE"
    report_stage '{"stage":"download_model","progress_pct":100}'
fi

# Drop the default portrait workflow into ComfyUI's user workflows folder so
# it shows up in the in-UI workflow list (Workflows > Open). Best-effort: a
# failed fetch must not abort provisioning — the user can still build a graph
# by hand, so we only log on failure.
if curl -fsSL --max-time 20 "$WORKFLOW_URL" -o "${WORKFLOW_DIR}/sdxl-portrait.json" 2>/dev/null; then
    log "installed default workflow -> ${WORKFLOW_DIR}/sdxl-portrait.json"
else
    log "could not fetch workflow.json from ${WORKFLOW_URL} (non-fatal)"
fi

# --- stage 3: start_server -----------------------------------------------

log "stage: start_server"
report_stage '{"stage":"start_server"}'

cd "$COMFYUI_DIR"
# --enable-manager: activates the ComfyUI Manager pip package installed
# during install_comfyui. Without this flag the manager is dormant and
# the in-UI "install missing nodes" button won't appear, defeating the
# point of preinstalling it.
nohup python3 main.py --listen 0.0.0.0 --port "$COMFYUI_PORT" --enable-manager \
    > /var/log/comfyui.log 2>&1 &
COMFYUI_PID=$!

# Wait for ComfyUI to actually bind the port before we report start_server
# done. We previously slept 5 seconds and reported success unconditionally —
# but if main.py crashes during import (driver/CUDA mismatch, missing dep,
# OOM), the user is left staring at a "preparing interface" spinner forever
# because the frontend never gets a failure signal. With the wait loop the
# frontend either gets a real `start_server` success or a stage with a
# `message` field it can surface as an error.
COMFYUI_BIND_TIMEOUT_S=90
for _ in $(seq 1 "$COMFYUI_BIND_TIMEOUT_S"); do
    if curl -fsS --max-time 1 "http://127.0.0.1:${COMFYUI_PORT}/" >/dev/null 2>&1; then
        report_stage "{\"stage\":\"start_server\",\"progress_pct\":100}"
        log "provisioning complete"
        exit 0
    fi
    # Bail early if python already died — no point waiting the full timeout.
    if ! kill -0 "$COMFYUI_PID" 2>/dev/null; then
        log "comfyui process exited before binding port ${COMFYUI_PORT}"
        # Surface the last few lines of the crash to the UI. report_stage's
        # JSON body cap is generous (~5s curl timeout) but messages still
        # have to fit in one POST, so truncate to 500 chars.
        tail_msg="$(tail -c 500 /var/log/comfyui.log 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/"/'"'"'/g')"
        report_stage "{\"stage\":\"start_server\",\"message\":\"ComfyUI crashed during startup: ${tail_msg}\"}"
        exit 1
    fi
    sleep 1
done

log "comfyui did not bind port ${COMFYUI_PORT} within ${COMFYUI_BIND_TIMEOUT_S}s"
report_stage "{\"stage\":\"start_server\",\"message\":\"ComfyUI did not become ready in ${COMFYUI_BIND_TIMEOUT_S}s. See /var/log/comfyui.log on the instance.\"}"
exit 1
