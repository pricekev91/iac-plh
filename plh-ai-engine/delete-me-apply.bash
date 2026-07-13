#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="apply"
SNAPSHOT_PREFIX="preapply"
ORIGINAL_ARGS=("$@")
LXD_SUBID_HOST_START="1000000"
LXD_SUBID_RANGE="1000000000"
DEFAULT_ENGINE_BACKEND="llama-cpp"
SUPPORTED_ENGINE_BACKENDS=("llama-cpp" "ollama")

print_engine_options() {
    local backend

    for backend in "${SUPPORTED_ENGINE_BACKENDS[@]}"; do
        printf '  - %s\n' "$backend"
    done
}

valid_engine_backend() {
    local candidate="$1"
    local backend

    for backend in "${SUPPORTED_ENGINE_BACKENDS[@]}"; do
        if [[ "$backend" == "$candidate" ]]; then
            return 0
        fi
    done

    return 1
}

detect_current_engine_backend() {
    local project="prod"
    local name="engine"
    local backend
    local model_env

    if ! command -v lxc >/dev/null 2>&1; then
        printf 'unknown\n'
        return 0
    fi

    if ! lxc info "$name" --project "$project" >/dev/null 2>&1; then
        printf 'none\n'
        return 0
    fi

    backend="$(lxc config get "$name" user.iac.engine_backend --project "$project" 2>/dev/null || true)"
    if valid_engine_backend "$backend"; then
        printf '%s\n' "$backend"
        return 0
    fi

    model_env="$(lxc config get "$name" environment.AI_ENGINE_MODEL --project "$project" 2>/dev/null || true)"
    if [[ -n "$model_env" ]]; then
        printf 'llama-cpp\n'
        return 0
    fi

    printf 'unknown\n'
}

usage() {
    cat <<'EOF'
Usage:
  ./apply.bash inventory/<host>.yaml
  ./apply.bash inventory/<host>.yaml <llama-cpp|ollama>
  ./apply.bash --plan inventory/<host>.yaml
  ./apply.bash --plan inventory/<host>.yaml <llama-cpp|ollama>

Modes:
  --plan   Validate inventory and print the reconciliation plan without executing LXD changes.
EOF

    printf '\nCurrent engine: %s\n' "$(detect_current_engine_backend)"
    printf 'Engine options:\n'
    print_engine_options
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "[apply] $*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

hash_text() {
    sha256sum | awk '{ print $1 }'
}

hash_file() {
    sha256sum "$1" | awk '{ print $1 }'
}

join_by_comma() {
    local first=1

    for value in "$@"; do
        if (( first )); then
            printf '%s' "$value"
            first=0
        else
            printf ',%s' "$value"
        fi
    done
}

default_root_pool() {
    lxc profile show default | awk '
        /^devices:/ { in_devices=1; next }
        in_devices && /^  root:$/ { in_root=1; next }
        in_root && /^    pool:/ { print $2; exit }
        in_root && /^  [^ ]/ { in_root=0 }
    '
}

default_profile_network() {
    lxc profile show default | awk '
        /^devices:/ { in_devices=1; next }
        in_devices && /^  eth0:$/ { in_eth0=1; next }
        in_eth0 && /^    network:/ { print $2; exit }
        in_eth0 && /^  [^ ]/ { in_eth0=0 }
    '
}

storage_pool_status() {
    local pool="$1"

    lxc storage show "$pool" | awk '
        /^status:/ { print $2; found=1; exit }
        END { exit(found ? 0 : 1) }
    '
}

subid_mapping_ready() {
    local mapping_file="$1"
    local account="$2"

    [[ -f "$mapping_file" ]] || return 1

    awk -F: -v account="$account" -v start="$LXD_SUBID_HOST_START" -v range="$LXD_SUBID_RANGE" '
        $1 == account && $2 == start && $3 == range { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$mapping_file"
}

require_lxd_subid_ready() {
    subid_mapping_ready /etc/subuid root || fail "Root subordinate UID range is not configured for LXD (${LXD_SUBID_HOST_START}:${LXD_SUBID_RANGE}). Run the host bootstrap/LXD initialization first, then rerun apply."
    subid_mapping_ready /etc/subgid root || fail "Root subordinate GID range is not configured for LXD (${LXD_SUBID_HOST_START}:${LXD_SUBID_RANGE}). Run the host bootstrap/LXD initialization first, then rerun apply."
    log "LXD subordinate UID/GID ranges ready"
}

require_lxd_storage_ready() {
    local pool
    local status

    pool="$(default_root_pool)"
    [[ -n "$pool" ]] || fail "Unable to determine the root storage pool from the global default LXD profile"

    status="$(storage_pool_status "$pool")" || fail "Unable to determine status for LXD storage pool: $pool"
    case "${status,,}" in
        available|created)
            log "LXD storage pool ready: $pool ($status)"
            ;;
        *)
            fail "LXD storage pool '$pool' is not ready (status: $status). Run the host bootstrap/LXD initialization first, then rerun apply."
            ;;
    esac
}

require_lxd_network_ready() {
    local network

    network="$(default_profile_network)"
    [[ -n "$network" ]] || fail "Unable to determine the default LXD bridge from the global default LXD profile"

    lxc network info "$network" >/dev/null 2>&1 || fail "LXD network '$network' is not ready. Run the host bootstrap/LXD initialization first, then rerun apply."
    log "LXD network ready: $network"
}

bootstrap_script_for_os() {
    local host_os="$1"

    case "${host_os,,}" in
        arch|cachyos)
            printf '%s/bootstrap/arch-cachyos.bash\n' "$SCRIPT_DIR"
            ;;
        *)
            fail "No bootstrap script defined for inventory host.os=$host_os"
            ;;
    esac
}

lxd_environment_ready() {
    local pool
    local status
    local network

    command -v lxc >/dev/null 2>&1 || return 1
    lxc info >/dev/null 2>&1 || return 1

    pool="$(default_root_pool 2>/dev/null || true)"
    [[ -n "$pool" ]] || return 1
    status="$(storage_pool_status "$pool" 2>/dev/null || true)"
    case "${status,,}" in
        available|created)
            ;;
        *)
            return 1
            ;;
    esac

    network="$(default_profile_network 2>/dev/null || true)"
    [[ -n "$network" ]] || return 1
    lxc network info "$network" >/dev/null 2>&1 || return 1

    subid_mapping_ready /etc/subuid root || return 1
    subid_mapping_ready /etc/subgid root || return 1
}

ensure_host_bootstrapped() {
    local host_os="$1"
    local bootstrap_script

    if lxd_environment_ready; then
        return 0
    fi

    bootstrap_script="$(bootstrap_script_for_os "$host_os")"
    [[ -f "$bootstrap_script" ]] || fail "Bootstrap script not found: $bootstrap_script"

    if [[ ${EUID} -ne 0 ]]; then
        require_command sudo
        log "LXD host prerequisites are missing or unready; re-running apply with sudo to bootstrap the host"
        exec sudo bash "$0" "${ORIGINAL_ARGS[@]}"
    fi

    log "LXD host prerequisites are missing or unready; running bootstrap: $bootstrap_script"
    bash "$bootstrap_script"
}

run_cmd() {
    if [[ "$MODE" == "plan" ]]; then
        printf '[plan]'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi

    "$@"
}

container_exists() {
    local project="$1"
    local name="$2"

    lxc info "$name" --project "$project" >/dev/null 2>&1
}

project_exists() {
    local project="$1"

    lxc project show "$project" >/dev/null 2>&1
}

profile_exists() {
    local profile="$1"

    lxc profile show "$profile" >/dev/null 2>&1
}

project_profile_exists() {
    local project="$1"
    local profile="$2"

    lxc profile show "$profile" --project "$project" >/dev/null 2>&1
}

container_config_get() {
    local project="$1"
    local name="$2"
    local key="$3"

    if [[ "$MODE" == "plan" ]]; then
        return 0
    fi

    lxc config get "$name" "$key" --project "$project" 2>/dev/null || true
}

project_cleanup_if_migrated() {
    local from_project="$1"
    local to_project="$2"

    [[ -n "$from_project" && -n "$to_project" ]] || return 0
    [[ "$from_project" != "$to_project" ]] || return 0

    if [[ "$MODE" == "plan" ]]; then
        printf '[plan] delete legacy project %q after containers have been migrated to %q and the legacy project is empty\n' "$from_project" "$to_project"
        return 0
    fi

    if ! project_exists "$from_project"; then
        return 0
    fi

    if ! project_exists "$to_project"; then
        return 0
    fi

    if lxc list --project "$from_project" --format csv -c n 2>/dev/null | grep -q '.'; then
        log "Legacy project still has instances; leaving in place for now: $from_project"
        return 0
    fi

    log "Delete empty legacy project: $from_project"
    run_cmd lxc project delete "$from_project" --force
}

container_config_keys() {
    local project="$1"
    local name="$2"

    if [[ "$MODE" == "plan" ]]; then
        return 0
    fi

    lxc config show "$name" --project "$project" | awk '
        /^config:$/ { in_config=1; next }
        in_config && /^[^ ]/ { exit }
        in_config && /^  [^ :]+:/ {
            key=$1
            sub(/:$/, "", key)
            print key
        }
    '
}

container_device_names() {
    local project="$1"
    local name="$2"

    if [[ "$MODE" == "plan" ]]; then
        return 0
    fi

    lxc config device list "$name" --project "$project"
}

container_has_device() {
    local project="$1"
    local name="$2"
    local device_name="$3"

    if [[ "$MODE" == "plan" ]]; then
        return 1
    fi

    container_device_names "$project" "$name" | grep -Fxq "$device_name"
}

container_device_get() {
    local project="$1"
    local name="$2"
    local device_name="$3"
    local key="$4"

    if [[ "$MODE" == "plan" ]]; then
        return 0
    fi

    lxc config device get "$name" "$device_name" "$key" --project "$project" 2>/dev/null || true
}

remove_stale_env_keys() {
    local project="$1"
    local name="$2"
    shift 2
    local desired_keys=("$@")
    local existing_key
    local keep_key
    local keep

    while IFS= read -r existing_key; do
        [[ "$existing_key" == environment.* ]] || continue

        keep=0
        for keep_key in "${desired_keys[@]}"; do
            if [[ "$existing_key" == "environment.${keep_key}" ]]; then
                keep=1
                break
            fi
        done

        if (( ! keep )); then
            run_cmd lxc config unset "$name" "$existing_key" --project "$project"
        fi
    done < <(container_config_keys "$project" "$name")
}

remove_stale_managed_devices() {
    local project="$1"
    local name="$2"
    local prefix="$3"
    shift 3
    local desired_devices=("$@")
    local existing_device
    local keep_device
    local keep

    while IFS= read -r existing_device; do
        [[ "$existing_device" == ${prefix}* ]] || continue

        keep=0
        for keep_device in "${desired_devices[@]}"; do
            if [[ "$existing_device" == "$keep_device" ]]; then
                keep=1
                break
            fi
        done

        if (( ! keep )); then
            run_cmd lxc config device remove "$name" "$existing_device" --project "$project"
        fi
    done < <(container_device_names "$project" "$name")
}

container_running() {
    local project="$1"
    local name="$2"

    if [[ "$MODE" == "plan" ]]; then
        return 1
    fi

    [[ "$(lxc info "$name" --project "$project" 2>/dev/null | awk '/^Status:/ { print $2; exit }')" == "RUNNING" ]]
}

shell_quote() {
    python3 - <<'PY' "$1"
import shlex
import sys

print(shlex.quote(sys.argv[1]))
PY
}

push_file_to_container() {
    local project="$1"
    local name="$2"
    local source_file="$3"
    local target_path="$4"
    local file_mode="$5"

    run_cmd lxc file push "$source_file" "${name}${target_path}" --project "$project" --create-dirs --mode="$file_mode"
}

container_file_hash() {
    local project="$1"
    local name="$2"
    local target_path="$3"

    lxc exec "$name" --project "$project" -- sh -lc "if [ -f $(shell_quote "$target_path") ]; then sha256sum $(shell_quote "$target_path") | awk '{ print \$1 }'; fi" 2>/dev/null || true
}

container_service_enabled_state() {
    local project="$1"
    local name="$2"
    local service_name="$3"

    lxc exec "$name" --project "$project" -- systemctl is-enabled "$service_name" 2>/dev/null || true
}

container_service_active_state() {
    local project="$1"
    local name="$2"
    local service_name="$3"

    lxc exec "$name" --project "$project" -- systemctl is-active "$service_name" 2>/dev/null || true
}

ensure_container_file_content() {
    local project="$1"
    local name="$2"
    local target_path="$3"
    local file_mode="$4"
    local content="$5"
    local local_hash
    local remote_hash

    local_hash="$(printf '%s' "$content" | hash_text)"
    remote_hash="$(container_file_hash "$project" "$name" "$target_path")"

    if [[ "$local_hash" == "$remote_hash" ]]; then
        return 1
    fi

    push_rendered_file_to_container "$project" "$name" "$target_path" "$file_mode" "$content"
    return 0
}

ensure_container_file_from_source() {
    local project="$1"
    local name="$2"
    local source_file="$3"
    local target_path="$4"
    local file_mode="$5"
    local local_hash
    local remote_hash

    local_hash="$(hash_file "$source_file")"
    remote_hash="$(container_file_hash "$project" "$name" "$target_path")"

    if [[ "$local_hash" == "$remote_hash" ]]; then
        return 1
    fi

    push_file_to_container "$project" "$name" "$source_file" "$target_path" "$file_mode"
    return 0
}

push_rendered_file_to_container() {
    local project="$1"
    local name="$2"
    local target_path="$3"
    local file_mode="$4"
    local content="$5"
    local temp_file

    temp_file="$(mktemp)"
    printf '%s' "$content" > "$temp_file"
    push_file_to_container "$project" "$name" "$temp_file" "$target_path" "$file_mode"
    rm -f "$temp_file"
}

render_runtime_environment_file() {
    local env_count="$1"
    local index="$2"
    local env_lines=""

    for ((e = 0; e < env_count; e++)); do
        env_key_var="PLATFORM_${index}_ENV_${e}_KEY"
        env_value_var="PLATFORM_${index}_ENV_${e}_VALUE"
        env_lines+="${!env_key_var}=$(shell_quote "${!env_value_var}")"$'\n'
    done

    printf '%s' "$env_lines"
}

render_service_unit() {
    local service_name="$1"
    local command_value="$2"
    local quoted_command

    quoted_command="$(shell_quote "$command_value")"
    cat <<EOF
[Unit]
Description=Managed runtime service for $service_name
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/$service_name
ExecStart=/bin/bash -lc $quoted_command
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

ensure_runtime_managed() {
    local project="$1"
    local name="$2"
    local platform_name="$3"
    local service_name="$4"
    local command_value="$5"
    local install_script="$6"
    local env_count="$7"
    local index="$8"
    local runtime_hash="$9"
    local current_runtime_hash
    local install_target="/root/iac/${service_name}/install.bash"
    local env_target="/etc/default/${service_name}"
    local unit_target="/etc/systemd/system/${service_name}.service"
    local env_content
    local unit_content
    local install_script_changed=0
    local env_changed=0
    local unit_changed=0
    local runtime_changed=0
    local installer_ran=0
    local service_enabled_state
    local service_active_state

    if [[ "$MODE" == "plan" ]]; then
        printf '[plan] push runtime install script %q into %q/%q and execute it when runtime hash changes\n' "$install_script" "$project" "$name"
        printf '[plan] write env file %q and systemd unit %q for %q\n' "$env_target" "$unit_target" "$service_name"
        printf '[plan] systemctl enable --now %q inside %q/%q\n' "$service_name" "$project" "$name"
        return 0
    fi

    current_runtime_hash="$(lxc config get "$name" user.iac.runtime_hash --project "$project" 2>/dev/null || true)"
    env_content="$(render_runtime_environment_file "$env_count" "$index")"
    unit_content="$(render_service_unit "$service_name" "$command_value")"
    service_enabled_state="$(container_service_enabled_state "$project" "$name" "$service_name")"
    service_active_state="$(container_service_active_state "$project" "$name" "$service_name")"

    if ensure_container_file_from_source "$project" "$name" "$install_script" "$install_target" 0755; then
        install_script_changed=1
    fi

    if ensure_container_file_content "$project" "$name" "$env_target" 0644 "$env_content"; then
        env_changed=1
    fi

    if ensure_container_file_content "$project" "$name" "$unit_target" 0644 "$unit_content"; then
        unit_changed=1
        run_cmd lxc exec "$name" --project "$project" -- systemctl daemon-reload
    fi

    if [[ "$current_runtime_hash" != "$runtime_hash" ]]; then
        runtime_changed=1
    fi

    if (( runtime_changed || install_script_changed )) || [[ "$service_enabled_state" == "not-found" || "$service_active_state" != "active" ]]; then
        log "Provision runtime for $project/$name from $install_script"
        run_cmd lxc exec "$name" --project "$project" -- bash "$install_target"
        installer_ran=1
    fi

    if (( runtime_changed || install_script_changed || env_changed || unit_changed || installer_ran )); then
        run_cmd lxc config set "$name" user.iac.runtime_hash "$runtime_hash" --project "$project"
    fi

    service_enabled_state="$(container_service_enabled_state "$project" "$name" "$service_name")"
    service_active_state="$(container_service_active_state "$project" "$name" "$service_name")"

    if [[ "$service_enabled_state" != "enabled" ]]; then
        run_cmd lxc exec "$name" --project "$project" -- systemctl enable "$service_name"
    fi

    if (( runtime_changed || install_script_changed || env_changed || unit_changed || installer_ran )); then
        if [[ "$service_active_state" == "active" ]]; then
            run_cmd lxc exec "$name" --project "$project" -- systemctl restart "$service_name"
        else
            run_cmd lxc exec "$name" --project "$project" -- systemctl start "$service_name"
        fi
    elif [[ "$service_active_state" != "active" ]]; then
        run_cmd lxc exec "$name" --project "$project" -- systemctl start "$service_name"
    fi
}

migrate_container_name_if_needed() {
    local legacy_project="$1"
    local legacy_container_name="$2"
    local target_project="$3"
    local target_container_name="$4"
    local target_runtime_hash

    [[ -n "$legacy_container_name" ]] || return 0
    [[ "$legacy_project/$legacy_container_name" != "$target_project/$target_container_name" ]] || return 0

    if [[ "$MODE" == "plan" ]]; then
        printf '[plan] move legacy container %q/%q to %q/%q when target is absent\n' "$legacy_project" "$legacy_container_name" "$target_project" "$target_container_name"
        return 0
    fi

    if ! container_exists "$legacy_project" "$legacy_container_name"; then
        return 0
    fi

    if container_exists "$target_project" "$target_container_name"; then
        target_runtime_hash="$(container_config_get "$target_project" "$target_container_name" user.iac.runtime_hash)"

        if container_running "$target_project" "$target_container_name" || [[ -n "$target_runtime_hash" ]]; then
            fail "Migration conflict: both $legacy_project/$legacy_container_name and $target_project/$target_container_name exist with meaningful state. Resolve the duplicate container before rerunning apply."
        fi

        log "Delete partial target container before migration: $target_project/$target_container_name"
        run_cmd lxc delete "$target_container_name" --project "$target_project"
    fi

    if container_running "$legacy_project" "$legacy_container_name"; then
        log "Stop legacy container before migration: $legacy_project/$legacy_container_name"
        run_cmd lxc stop "$legacy_container_name" --project "$legacy_project"
    fi

    log "Rename container: $legacy_project/$legacy_container_name -> $target_project/$target_container_name"
    if [[ "$legacy_project" == "$target_project" ]]; then
        run_cmd lxc move "$legacy_container_name" "$target_container_name" --project "$legacy_project"
    else
        run_cmd lxc move "$legacy_container_name" "$target_container_name" --project "$legacy_project" --target-project "$target_project"
    fi
}

resolve_image_alias() {
    local image="$1"

    if lxc image info "$image" >/dev/null 2>&1; then
        printf '%s\n' "$image"
        return 0
    fi

    if [[ "$image" == "images:ubuntu/24.04" ]]; then
        log "Image alias fallback: images:ubuntu/24.04 -> ubuntu:24.04"
        printf '%s\n' "ubuntu:24.04"
        return 0
    fi

    printf '%s\n' "$image"
}

snapshot_container() {
    local project="$1"
    local name="$2"
    local snapshot_name="$3"

    log "Create snapshot: $project/$name@$snapshot_name"
    run_cmd lxc snapshot "$name" "$snapshot_name" --project "$project"
}

replace_container() {
    local project="$1"
    local name="$2"
    local image="$3"
    local snapshot_name="$4"

    snapshot_container "$project" "$name" "$snapshot_name"
    run_cmd lxc stop "$name" --project "$project" --force || true
    run_cmd lxc delete "$name" --project "$project"
    run_cmd lxc init "$image" "$name" --project "$project"
}

sync_project_default_profile() {
    local project="$1"

    if [[ "$MODE" == "plan" ]]; then
        printf '[plan] sync project default profile from global default for %q\n' "$project"
        return 0
    fi

    if ! project_profile_exists "$project" default; then
        run_cmd lxc profile create default --project "$project"
    fi

    log "Sync project default profile from global default: $project/default"
    lxc profile show default | lxc profile edit default --project "$project"
}

ensure_project_gpu_profile() {
    local project="$1"
    local profile="$2"
    local profile_file="$3"

    log "Ensure project profile from $profile_file in $project"
    if [[ "$MODE" == "apply" ]]; then
        if ! project_profile_exists "$project" "$profile"; then
            run_cmd lxc profile create "$profile" --project "$project"
        else
            log "Project profile already present: $project/$profile"
        fi

        render_profile_yaml "$profile_file" | lxc profile edit "$profile" --project "$project"
    else
        run_cmd lxc profile create "$profile" --project "$project"
        printf '[plan] lxc profile edit %q --project %q < %q\n' "$profile" "$project" "$profile_file"
    fi
}

render_profile_yaml() {
    local profile_file="$1"

    python3 - "$profile_file" <<'PY'
import pathlib
import sys

profile_path = pathlib.Path(sys.argv[1])
content = profile_path.read_text().splitlines()
indent_stack = [(-1, {})]

def parse_scalar(value):
    if value == "{}":
        return {}
    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    return value.strip('"')

root = {}
stack = [(-1, root)]

for raw_line in content:
    if not raw_line.strip() or raw_line.lstrip().startswith("#"):
        continue
    indent = len(raw_line) - len(raw_line.lstrip(" "))
    line = raw_line.strip()
    while stack and indent <= stack[-1][0]:
        stack.pop()
    current = stack[-1][1]
    key, _, value = line.partition(":")
    key = key.strip()
    value = value.strip()
    if not value:
        current[key] = {}
        stack.append((indent, current[key]))
    else:
        current[key] = parse_scalar(value)

print("config:")
config = root.get("config", {})
if config:
    for key, value in config.items():
        print(f"  {key}: {str(value).lower() if isinstance(value, bool) else value}")
print(f"description: {root.get('description', '')}")
print("devices:")
for device_name, device in root.get("devices", {}).items():
    print(f"  {device_name}:")
    for key, value in device.items():
        print(f"    {key}: {value}")
print(f"name: {root.get('name', '')}")
PY
}

parse_state() {
    local inventory_path="$1"
    local engine_backend="$2"

    python3 - "$inventory_path" "$SCRIPT_DIR" "$engine_backend" <<'PY'
import json
import os
import pathlib
import re
import sys

inventory_path = pathlib.Path(sys.argv[1]).resolve()
repo_root = pathlib.Path(sys.argv[2]).resolve()
engine_backend = sys.argv[3]

SUPPORTED_ENGINE_BACKENDS = {'llama-cpp', 'ollama'}

if engine_backend not in SUPPORTED_ENGINE_BACKENDS:
    fail(f'Unsupported engine backend: {engine_backend}')

def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

def parse_scalar(value):
    lowered = value.lower()
    if lowered == 'true':
        return True
    if lowered == 'false':
        return False
    if re.fullmatch(r'-?\d+', value):
        return int(value)
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        return value[1:-1]
    return value

def parse_yaml_lines(lines):
    root = {}
    stack = [(-1, root)]

    index = 0
    while index < len(lines):
        raw_line = lines[index]
        line = raw_line.rstrip('\n')
        if not line.strip() or line.lstrip().startswith('#'):
            index += 1
            continue

        indent = len(line) - len(line.lstrip(' '))
        stripped = line.strip()

        while len(stack) > 1 and indent <= stack[-1][0]:
            stack.pop()

        parent = stack[-1][1]

        if stripped.startswith('- '):
            value = stripped[2:].strip()
            if not isinstance(parent, list):
                fail(f'Invalid list item: {stripped}')

            if ': ' in value:
                key, raw_val = value.split(':', 1)
                item = {key.strip(): parse_scalar(raw_val.strip())}
                parent.append(item)
                stack.append((indent, item))
            else:
                parent.append(parse_scalar(value))
            index += 1
            continue

        if ':' not in stripped:
            fail(f'Invalid line: {stripped}')

        key, raw_val = stripped.split(':', 1)
        key = key.strip()
        raw_val = raw_val.strip()

        if raw_val == '':
            next_container = {}
            next_meaningful = None
            for candidate in lines[index + 1:]:
                if not candidate.strip() or candidate.lstrip().startswith('#'):
                    continue
                next_meaningful = candidate
                break

            if next_meaningful is not None:
                next_indent = len(next_meaningful) - len(next_meaningful.lstrip(' '))
                next_stripped = next_meaningful.strip()
                if next_indent > indent and next_stripped.startswith('- '):
                    next_container = []

            if isinstance(parent, list):
                fail(f'Unexpected mapping key in list context: {key}')

            parent[key] = next_container
            stack.append((indent, next_container))
            index += 1
            continue

        if raw_val == '>':
            folded = []
            continue_indent = None
            look_ahead = index + 1
            while look_ahead < len(lines):
                candidate = lines[look_ahead]
                if not candidate.strip():
                    look_ahead += 1
                    continue
                candidate_indent = len(candidate) - len(candidate.lstrip(' '))
                if candidate_indent <= indent:
                    break
                if continue_indent is None:
                    continue_indent = candidate_indent
                folded.append(candidate[continue_indent:].rstrip())
                look_ahead += 1

            if isinstance(parent, list):
                fail(f'Unexpected folded scalar in list context: {key}')
            parent[key] = ' '.join(part for part in folded if part)
            index = look_ahead
            continue

        if isinstance(parent, list):
            fail(f'Unexpected mapping key in list context: {key}')

        parent[key] = parse_scalar(raw_val)
        index += 1

    return root

def parse_yaml_file(path):
    lines = path.read_text().splitlines()
    return parse_yaml_lines(lines)

def render_template(value, host):
    def replace(match):
        source = match.group(1)
        key = match.group(2)
        if source == 'host':
            if key not in host:
                fail(f'Missing inventory host key for template substitution: {key}')
            return str(host[key])
        if source == 'env':
            if key not in os.environ:
                fail(f'Missing operator environment variable for template substitution: {key}')
            return os.environ[key]
        fail(f'Unsupported template source: {source}')

    return re.sub(r'\{\{\s*(host|env)\.([a-zA-Z0-9_]+)\s*\}\}', replace, str(value))

inventory = parse_yaml_file(inventory_path)

host = inventory.get('host', {})
projects = inventory.get('projects', [])
project_migrations = inventory.get('project_migrations', [])
platform_names = inventory.get('platforms', [])
network = inventory.get('network', {})

if engine_backend == 'ollama' and 'presentation' not in platform_names:
    if 'engine' in platform_names:
        engine_index = platform_names.index('engine')
        platform_names = platform_names[:engine_index + 1] + ['presentation'] + platform_names[engine_index + 1:]
    else:
        platform_names = ['presentation'] + platform_names

required_host_keys = ['id', 'os', 'gpu', 'model_dir', 'ai_engine_model']
for key in required_host_keys:
    if key not in host:
        fail(f'Missing inventory host key: {key}')

if not projects:
    fail('Inventory must define at least one project')

if not platform_names:
    fail('Inventory must define at least one platform')

gpu_profile_map = {
    'nvidia': 'gpu-nvidia',
    'amd': 'gpu-amd',
    'intel': 'gpu-intel',
}

gpu_vendor = str(host['gpu']).lower()
gpu_profile = gpu_profile_map.get(gpu_vendor)
if gpu_profile is None:
    fail(f'Unsupported GPU vendor in inventory: {host["gpu"]}')

profile_file = repo_root / 'profiles' / f'{gpu_profile}.yaml'
if not profile_file.exists():
    fail(f'GPU profile file not found: {profile_file}')

platforms = []
for platform_name in platform_names:
    platform_file = repo_root / 'platforms' / f'{platform_name}.yaml'
    if not platform_file.exists():
        fail(f'Platform file not found: {platform_file}')

    platform = parse_yaml_file(platform_file)
    container = platform.get('container', {})
    mounts = container.get('mounts', [])
    env = container.get('env', {})
    profiles = container.get('profiles', [])
    ports = platform.get('ports', [])
    runtime = platform.get('runtime', {})
    migration = platform.get('migration', {})

    host_model_dir = str(host['model_dir'])
    resolved_mounts = []
    for mount in mounts:
        mount_host = render_template(mount.get('host', ''), host)
        resolved_mounts.append({
            'host': mount_host,
            'container': mount['container'],
            'readonly': bool(mount.get('readonly', False)),
        })

    resolved_profiles = []
    for profile in profiles:
        resolved_profiles.append(gpu_profile if profile == 'gpu' else profile)

    resolved_ports = []
    expose_ui = bool(network.get('expose_ui', False))
    for port in ports:
        bind_local_only = bool(port.get('bind_local_only', False))
        listen = '127.0.0.1' if bind_local_only and not expose_ui else '0.0.0.0'
        resolved_ports.append({
            'host': int(port['host']),
            'container': int(port['container']),
            'listen': listen,
        })

    install_script = runtime.get('install_script')
    service_name = runtime.get('service_name', platform['name'])
    if platform_name == 'engine':
        install_script = runtime.get('install_script_by_backend', {}).get(engine_backend, install_script)
    if not install_script:
        fail(f'Platform runtime.install_script is required: {platform_name}')

    resolved_env = {}
    for key, value in env.items():
        resolved_env[key] = render_template(value, host)

    if platform_name == 'engine':
        resolved_env['AI_ENGINE_BACKEND'] = engine_backend

    resolved_command = render_template(container['command'], host)

    install_script_path = (repo_root / install_script).resolve()
    if not install_script_path.exists():
        fail(f'Runtime install script not found: {install_script_path}')

    platforms.append({
        'name': platform['name'],
        'project': platform['project'],
        'container_name': container['name'],
        'legacy_project': migration.get('legacy_project', platform['project']),
        'legacy_container_name': migration.get('legacy_container_name', ''),
        'image': container['image'],
        'profiles': resolved_profiles,
        'mounts': resolved_mounts,
        'env': resolved_env,
        'command': resolved_command,
        'ports': resolved_ports,
        'runtime_install_script': str(install_script_path),
        'runtime_service_name': service_name,
        'engine_backend': engine_backend if platform_name == 'engine' else '',
    })

state = {
    'inventory': str(inventory_path),
    'host': host,
    'projects': projects,
    'project_migrations': project_migrations,
    'gpu_profile': gpu_profile,
    'gpu_profile_file': str(profile_file),
    'platforms': platforms,
}

print(json.dumps(state))
PY
}

engine_backend="$DEFAULT_ENGINE_BACKEND"

if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

case "$1" in
    --help|-h|help)
        usage
        exit 0
        ;;
    --plan)
        MODE="plan"
        shift
        ;;
esac

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 1
fi

inventory_file="$1"
if [[ $# -eq 2 ]]; then
    engine_backend="$2"
fi

valid_engine_backend "$engine_backend" || fail "Unsupported engine backend: $engine_backend"

[[ -f "$inventory_file" ]] || fail "Inventory file not found: $inventory_file"
require_command python3
require_command sha256sum

state_json="$(parse_state "$inventory_file" "$engine_backend")"

eval "$(python3 - <<'PY' "$state_json"
import json
import shlex
import sys

state = json.loads(sys.argv[1])

def emit(name, value):
    print(f'{name}={shlex.quote(str(value))}')

emit('HOST_ID', state['host']['id'])
emit('HOST_OS', state['host']['os'])
emit('GPU_PROFILE', state['gpu_profile'])
emit('GPU_PROFILE_FILE', state['gpu_profile_file'])
emit('ENGINE_BACKEND', next((platform['engine_backend'] for platform in state['platforms'] if platform['name'] == 'engine'), ''))
emit('PROJECT_COUNT', len(state['projects']))
emit('PROJECT_MIGRATION_COUNT', len(state['project_migrations']))
emit('PLATFORM_COUNT', len(state['platforms']))

for index, project in enumerate(state['projects']):
    emit(f'PROJECT_{index}', project)

for index, migration in enumerate(state['project_migrations']):
    emit(f'PROJECT_MIGRATION_{index}_FROM', migration['from'])
    emit(f'PROJECT_MIGRATION_{index}_TO', migration['to'])

for index, platform in enumerate(state['platforms']):
    emit(f'PLATFORM_{index}_NAME', platform['name'])
    emit(f'PLATFORM_{index}_PROJECT', platform['project'])
    emit(f'PLATFORM_{index}_CONTAINER_NAME', platform['container_name'])
    emit(f'PLATFORM_{index}_LEGACY_PROJECT', platform['legacy_project'])
    emit(f'PLATFORM_{index}_LEGACY_CONTAINER_NAME', platform['legacy_container_name'])
    emit(f'PLATFORM_{index}_IMAGE', platform['image'])
    emit(f'PLATFORM_{index}_COMMAND', platform['command'])
    emit(f'PLATFORM_{index}_RUNTIME_INSTALL_SCRIPT', platform['runtime_install_script'])
    emit(f'PLATFORM_{index}_RUNTIME_SERVICE_NAME', platform['runtime_service_name'])
    emit(f'PLATFORM_{index}_ENGINE_BACKEND', platform['engine_backend'])
    emit(f'PLATFORM_{index}_PROFILE_COUNT', len(platform['profiles']))
    emit(f'PLATFORM_{index}_MOUNT_COUNT', len(platform['mounts']))
    emit(f'PLATFORM_{index}_ENV_COUNT', len(platform['env']))
    emit(f'PLATFORM_{index}_PORT_COUNT', len(platform['ports']))

    for p_index, profile in enumerate(platform['profiles']):
        emit(f'PLATFORM_{index}_PROFILE_{p_index}', profile)

    for m_index, mount in enumerate(platform['mounts']):
        emit(f'PLATFORM_{index}_MOUNT_{m_index}_HOST', mount['host'])
        emit(f'PLATFORM_{index}_MOUNT_{m_index}_CONTAINER', mount['container'])
        emit(f'PLATFORM_{index}_MOUNT_{m_index}_READONLY', str(mount['readonly']).lower())

    for e_index, (key, value) in enumerate(platform['env'].items()):
        emit(f'PLATFORM_{index}_ENV_{e_index}_KEY', key)
        emit(f'PLATFORM_{index}_ENV_{e_index}_VALUE', value)

    for port_index, port in enumerate(platform['ports']):
        emit(f'PLATFORM_{index}_PORT_{port_index}_HOST', port['host'])
        emit(f'PLATFORM_{index}_PORT_{port_index}_CONTAINER', port['container'])
        emit(f'PLATFORM_{index}_PORT_{port_index}_LISTEN', port['listen'])
PY
)"

log "Host: $HOST_ID"
log "Mode: $MODE"
log "Resolved GPU profile: $GPU_PROFILE"
log "Requested engine backend: ${ENGINE_BACKEND:-$engine_backend}"

if [[ "$MODE" == "apply" ]]; then
    ensure_host_bootstrapped "$HOST_OS"
    require_command lxc
    require_lxd_storage_ready
    require_lxd_network_ready
    require_lxd_subid_ready
fi

for ((i = 0; i < PROJECT_COUNT; i++)); do
    project_var="PROJECT_${i}"
    project_name="${!project_var}"
    log "Ensure project: $project_name"

    if [[ "$MODE" == "apply" ]]; then
        require_command lxc
        if ! project_exists "$project_name"; then
            run_cmd lxc project create "$project_name"
        else
            log "Project already present: $project_name"
        fi

        sync_project_default_profile "$project_name"
    else
        run_cmd lxc project create "$project_name"
        printf '[plan] sync project default profile from global default for %q\n' "$project_name"
    fi
done

log "Use GPU profile definition from $GPU_PROFILE_FILE"

for ((i = 0; i < PLATFORM_COUNT; i++)); do
    name_var="PLATFORM_${i}_NAME"
    project_var="PLATFORM_${i}_PROJECT"
    container_var="PLATFORM_${i}_CONTAINER_NAME"
    legacy_project_var="PLATFORM_${i}_LEGACY_PROJECT"
    legacy_container_var="PLATFORM_${i}_LEGACY_CONTAINER_NAME"
    image_var="PLATFORM_${i}_IMAGE"
    command_var="PLATFORM_${i}_COMMAND"
    runtime_install_script_var="PLATFORM_${i}_RUNTIME_INSTALL_SCRIPT"
    runtime_service_name_var="PLATFORM_${i}_RUNTIME_SERVICE_NAME"
    engine_backend_var="PLATFORM_${i}_ENGINE_BACKEND"
    profile_count_var="PLATFORM_${i}_PROFILE_COUNT"
    mount_count_var="PLATFORM_${i}_MOUNT_COUNT"
    env_count_var="PLATFORM_${i}_ENV_COUNT"
    port_count_var="PLATFORM_${i}_PORT_COUNT"

    platform_name="${!name_var}"
    project_name="${!project_var}"
    container_name="${!container_var}"
    legacy_project_name="${!legacy_project_var}"
    legacy_container_name="${!legacy_container_var}"
    image_name="${!image_var}"
    resolved_image_name="$image_name"
    command_value="${!command_var}"
    runtime_install_script="${!runtime_install_script_var}"
    runtime_service_name="${!runtime_service_name_var}"
    resolved_engine_backend="${!engine_backend_var}"
    profile_count="${!profile_count_var}"
    mount_count="${!mount_count_var}"
    env_count="${!env_count_var}"
    port_count="${!port_count_var}"

    log "Reconciling platform: $platform_name"
    snapshot_name="${SNAPSHOT_PREFIX}-$(date +%Y%m%d%H%M%S)-${platform_name}"

    if [[ "$runtime_service_name" != "$container_name" ]]; then
        migrate_container_name_if_needed "$project_name" "$runtime_service_name" "$project_name" "$container_name"
        if [[ "$legacy_project_name" != "$project_name" ]]; then
            migrate_container_name_if_needed "$legacy_project_name" "$runtime_service_name" "$project_name" "$container_name"
        fi
    fi

    migrate_container_name_if_needed "$project_name" "$legacy_container_name" "$project_name" "$container_name"
    if [[ "$legacy_project_name" != "$project_name" ]]; then
        migrate_container_name_if_needed "$legacy_project_name" "$legacy_container_name" "$project_name" "$container_name"
    fi

    profile_args=()
    for ((p = 0; p < profile_count; p++)); do
        profile_var="PLATFORM_${i}_PROFILE_${p}"
        profile_args+=("${!profile_var}")
    done
    profile_csv="$(join_by_comma "${profile_args[@]}")"

    desired_env_keys=()
    for ((e = 0; e < env_count; e++)); do
        env_key_var="PLATFORM_${i}_ENV_${e}_KEY"
        desired_env_keys+=("${!env_key_var}")
    done

    desired_mount_devices=()
    for ((m = 0; m < mount_count; m++)); do
        desired_mount_devices+=("disk-${platform_name}-${m}")
    done

    desired_proxy_devices=()
    for ((p = 0; p < port_count; p++)); do
        desired_proxy_devices+=("proxy-${platform_name}-${p}")
    done

    runtime_hash="$(
        {
            printf 'service_name=%s\n' "$runtime_service_name"
            printf 'engine_backend=%s\n' "$resolved_engine_backend"
            printf 'command=%s\n' "$command_value"
            printf 'install_script_hash=%s\n' "$(hash_file "$runtime_install_script")"

            for ((e = 0; e < env_count; e++)); do
                env_key_var="PLATFORM_${i}_ENV_${e}_KEY"
                env_value_var="PLATFORM_${i}_ENV_${e}_VALUE"
                printf 'env=%s|%s\n' "${!env_key_var}" "${!env_value_var}"
            done
        } | hash_text
    )"

    for profile_name in "${profile_args[@]}"; do
        if [[ "$profile_name" == "$GPU_PROFILE" ]]; then
            ensure_project_gpu_profile "$project_name" "$GPU_PROFILE" "$GPU_PROFILE_FILE"
        fi
    done

    desired_state_hash="$(
        {
            printf 'image=%s\n' "$image_name"
            printf 'engine_backend=%s\n' "$resolved_engine_backend"
            printf 'command=%s\n' "$command_value"

            for profile_name in "${profile_args[@]}"; do
                printf 'profile=%s\n' "$profile_name"
            done

            for ((m = 0; m < mount_count; m++)); do
                mount_host_var="PLATFORM_${i}_MOUNT_${m}_HOST"
                mount_container_var="PLATFORM_${i}_MOUNT_${m}_CONTAINER"
                mount_ro_var="PLATFORM_${i}_MOUNT_${m}_READONLY"
                printf 'mount=%s|%s|%s\n' "${!mount_host_var}" "${!mount_container_var}" "${!mount_ro_var}"
            done

            for ((e = 0; e < env_count; e++)); do
                env_key_var="PLATFORM_${i}_ENV_${e}_KEY"
                env_value_var="PLATFORM_${i}_ENV_${e}_VALUE"
                printf 'env=%s|%s\n' "${!env_key_var}" "${!env_value_var}"
            done

            for ((p = 0; p < port_count; p++)); do
                host_port_var="PLATFORM_${i}_PORT_${p}_HOST"
                container_port_var="PLATFORM_${i}_PORT_${p}_CONTAINER"
                listen_var="PLATFORM_${i}_PORT_${p}_LISTEN"
                printf 'port=%s|%s|%s\n' "${!host_port_var}" "${!container_port_var}" "${!listen_var}"
            done
        } | hash_text
    )"

    if [[ "$MODE" == "apply" ]]; then
        require_command lxc
        resolved_image_name="$(resolve_image_alias "$image_name")"
        if ! container_exists "$project_name" "$container_name"; then
            init_args=(lxc init "$resolved_image_name" "$container_name" --project "$project_name")
            run_cmd "${init_args[@]}"
        else
            current_state_hash="$(lxc config get "$container_name" user.iac.desired_state_hash --project "$project_name" 2>/dev/null || true)"
            if [[ "$current_state_hash" == "$desired_state_hash" ]]; then
                log "Desired state unchanged; keeping container: $project_name/$container_name"
            else
                log "Container exists and desired state changed; replacing: $project_name/$container_name"
                replace_container "$project_name" "$container_name" "$resolved_image_name" "$snapshot_name"
            fi
        fi
    else
        log "Plan includes conditional replacement workflow for changed containers: $project_name/$container_name"
        printf '[plan] compare desired-state hash for %q/%q and replace only when changed\n' "$project_name" "$container_name"
        printf '[plan] lxc snapshot create %q %q --project %q (only before replacement)\n' "$container_name" "$snapshot_name" "$project_name"
        printf '[plan] lxc stop %q --project %q --force (only before replacement)\n' "$container_name" "$project_name"
        printf '[plan] lxc delete %q --project %q (only before replacement)\n' "$container_name" "$project_name"
        init_args=(lxc init "$image_name" "$container_name" --project "$project_name")
        run_cmd "${init_args[@]}"
    fi

    if (( profile_count > 0 )); then
        profile_assign_args=(lxc profile assign "$container_name" "$profile_csv" --project "$project_name")
        run_cmd "${profile_assign_args[@]}"
    fi

    remove_stale_env_keys "$project_name" "$container_name" "${desired_env_keys[@]}"
    remove_stale_managed_devices "$project_name" "$container_name" "disk-${platform_name}-" "${desired_mount_devices[@]}"
    remove_stale_managed_devices "$project_name" "$container_name" "proxy-${platform_name}-" "${desired_proxy_devices[@]}"
    if [[ "$runtime_service_name" != "$platform_name" ]]; then
        remove_stale_managed_devices "$project_name" "$container_name" "disk-${runtime_service_name}-"
        remove_stale_managed_devices "$project_name" "$container_name" "proxy-${runtime_service_name}-"
    fi
    if [[ -n "$legacy_container_name" && "$legacy_container_name" != "$platform_name" ]]; then
        remove_stale_managed_devices "$project_name" "$container_name" "disk-${legacy_container_name}-"
        remove_stale_managed_devices "$project_name" "$container_name" "proxy-${legacy_container_name}-"
    fi

    for ((m = 0; m < mount_count; m++)); do
        mount_host_var="PLATFORM_${i}_MOUNT_${m}_HOST"
        mount_container_var="PLATFORM_${i}_MOUNT_${m}_CONTAINER"
        mount_ro_var="PLATFORM_${i}_MOUNT_${m}_READONLY"
        device_name="disk-${platform_name}-${m}"
        readonly_flag="${!mount_ro_var}"

        current_source="$(container_device_get "$project_name" "$container_name" "$device_name" source)"
        current_path="$(container_device_get "$project_name" "$container_name" "$device_name" path)"
        current_readonly="$(container_device_get "$project_name" "$container_name" "$device_name" readonly)"
        [[ -n "$current_readonly" ]] || current_readonly="false"

        if ! container_has_device "$project_name" "$container_name" "$device_name"; then
            device_args=(lxc config device add "$container_name" "$device_name" disk "source=${!mount_host_var}" "path=${!mount_container_var}" --project "$project_name")
            if [[ "$readonly_flag" == "true" ]]; then
                device_args+=(readonly=true)
            fi
            run_cmd "${device_args[@]}"
        elif [[ "$current_source" != "${!mount_host_var}" || "$current_path" != "${!mount_container_var}" || "$current_readonly" != "$readonly_flag" ]]; then
            run_cmd lxc config device remove "$container_name" "$device_name" --project "$project_name"
            device_args=(lxc config device add "$container_name" "$device_name" disk "source=${!mount_host_var}" "path=${!mount_container_var}" --project "$project_name")
            if [[ "$readonly_flag" == "true" ]]; then
                device_args+=(readonly=true)
            fi
            run_cmd "${device_args[@]}"
        fi
    done

    for ((e = 0; e < env_count; e++)); do
        env_key_var="PLATFORM_${i}_ENV_${e}_KEY"
        env_value_var="PLATFORM_${i}_ENV_${e}_VALUE"
        run_cmd lxc config set "$container_name" "environment.${!env_key_var}" "${!env_value_var}" --project "$project_name"
    done

    run_cmd lxc config set "$container_name" user.command "$command_value" --project "$project_name"
    run_cmd lxc config set "$container_name" user.iac.desired_state_hash "$desired_state_hash" --project "$project_name"
    if [[ -n "$resolved_engine_backend" ]]; then
        run_cmd lxc config set "$container_name" user.iac.engine_backend "$resolved_engine_backend" --project "$project_name"
    fi

    for ((p = 0; p < port_count; p++)); do
        host_port_var="PLATFORM_${i}_PORT_${p}_HOST"
        container_port_var="PLATFORM_${i}_PORT_${p}_CONTAINER"
        listen_var="PLATFORM_${i}_PORT_${p}_LISTEN"
        proxy_name="proxy-${platform_name}-${p}"
        connect_target="tcp:127.0.0.1:${!container_port_var}"
        listen_target="tcp:${!listen_var}:${!host_port_var}"
        current_listen="$(container_device_get "$project_name" "$container_name" "$proxy_name" listen)"
        current_connect="$(container_device_get "$project_name" "$container_name" "$proxy_name" connect)"

        if ! container_has_device "$project_name" "$container_name" "$proxy_name"; then
            run_cmd lxc config device add "$container_name" "$proxy_name" proxy "listen=$listen_target" "connect=$connect_target" --project "$project_name"
        elif [[ "$current_listen" != "$listen_target" || "$current_connect" != "$connect_target" ]]; then
            run_cmd lxc config device remove "$container_name" "$proxy_name" --project "$project_name"
            run_cmd lxc config device add "$container_name" "$proxy_name" proxy "listen=$listen_target" "connect=$connect_target" --project "$project_name"
        fi
    done

    if [[ "$MODE" == "apply" ]]; then
        if ! container_running "$project_name" "$container_name"; then
            run_cmd lxc start "$container_name" --project "$project_name"
        fi
    else
        run_cmd lxc start "$container_name" --project "$project_name"
    fi

    ensure_runtime_managed "$project_name" "$container_name" "$platform_name" "$runtime_service_name" "$command_value" "$runtime_install_script" "$env_count" "$i" "$runtime_hash"
done

for ((i = 0; i < PROJECT_MIGRATION_COUNT; i++)); do
    project_migration_from_var="PROJECT_MIGRATION_${i}_FROM"
    project_migration_to_var="PROJECT_MIGRATION_${i}_TO"
    project_cleanup_if_migrated "${!project_migration_from_var}" "${!project_migration_to_var}"
done

log "Reconciliation complete"