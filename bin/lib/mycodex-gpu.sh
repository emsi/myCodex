#!/usr/bin/env bash
# Host-side GPU discovery and Compose configuration. No image changes are
# needed: device groups use the entrypoint's existing MYCODEX_HOST_GROUPS path.

GPU_OPTION_SPECIFIED=0
GPU_REQUEST=none
GPU_MODE=none
GPU_REASON="disabled by default"
GPU_DEVICES=()
GPU_COMPOSE_FILE=""
GPU_HOST_GROUPS=""

set_gpu_request() {
  [[ "${GPU_OPTION_SPECIFIED}" == 0 ]] || die "GPU mode was specified more than once"
  GPU_OPTION_SPECIFIED=1
  GPU_REQUEST="$(normalize_gpu_request "$1")" \
    || die "GPU mode must be auto, none, or a comma-separated list of nvidia, amd, intel: $1"
}

normalize_gpu_request() {
  local request="$1" vendor result=""
  case "${request}" in
    auto|none) printf '%s\n' "${request}"; return ;;
  esac
  [[ "${request}" =~ ^(amd|intel|nvidia)(,(amd|intel|nvidia))*$ ]] || return 1
  for vendor in amd intel nvidia; do
    if [[ ",${request}," == *",${vendor},"* ]]; then
      result+="${result:+,}${vendor}"
    fi
  done
  printf '%s\n' "${result}"
}

gpu_device_exists() { [[ -c "$1" ]]; }

gpu_render_nodes() {
  local node
  for node in /dev/dri/renderD*; do
    if gpu_device_exists "${node}"; then printf '%s\n' "${node}"; fi
  done
}

gpu_vendor_for_node() {
  local vendor
  vendor="$(cat "/sys/class/drm/${1##*/}/device/vendor" 2>/dev/null)" || return 1
  case "${vendor,,}" in
    0x1002) printf 'amd\n' ;;
    0x8086) printf 'intel\n' ;;
    0x10de) printf 'nvidia\n' ;;
    *) return 1 ;;
  esac
}

# World-readable/writable nodes need no supplementary group. Otherwise use
# numeric device ownership, not distribution-specific render/video group IDs.
gpu_device_group() {
  local gid mode
  read -r gid mode < <(stat -Lc '%g %a' -- "$1")
  [[ "${gid}" =~ ^[0-9]+$ && "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  if (( (8#${mode} & 6) != 6 )); then printf '%s\n' "${gid}"; fi
  return 0
}

gpu_local_host() {
  if [[ "$(uname -s)" != Linux ]] || ! local_docker_daemon; then
    GPU_REASON="GPU discovery requires a local native Linux Docker Engine; remote daemons and Docker Desktop are unsupported"
    return 1
  fi
}

gpu_check_nvidia() {
  local devices runtimes
  if ! devices="$(nvidia-smi -L 2>/dev/null)" || [[ -z "${devices}" ]]; then
    GPU_REASON="NVIDIA GPU unavailable; install a working host NVIDIA driver (nvidia-smi -L must list a GPU)"
    return 1
  fi
  if ! runtimes="$(docker info --format '{{json .Runtimes}}' 2>/dev/null)" \
    || [[ "${runtimes}" != *'"nvidia"'* ]]; then
    GPU_REASON="NVIDIA Container Toolkit is not configured for this Docker Engine; install it and configure its nvidia runtime"
    return 1
  fi
}

detect_gpu() {
  local request="${GPU_REQUEST}" node vendor selected="" nvidia_present=0
  local -a nodes vendors
  GPU_MODE=none
  GPU_DEVICES=()
  GPU_REASON="disabled"
  [[ "${request}" != none ]] || return 0
  gpu_local_host || return 1
  mapfile -t nodes < <(gpu_render_nodes)
  vendors=()
  for node in "${nodes[@]}"; do
    vendor="$(gpu_vendor_for_node "${node}")" || vendor=unknown
    vendors+=("${vendor}")
    [[ "${vendor}" != nvidia ]] || nvidia_present=1
  done
  if gpu_device_exists /dev/nvidiactl; then nvidia_present=1; fi
  if [[ "${request}" == auto ]]; then
    for vendor in amd intel; do
      if [[ " ${vendors[*]} " == *" ${vendor} "* ]]; then selected+="${selected:+,}${vendor}"; fi
    done
    if [[ "${nvidia_present}" == 1 ]]; then selected+="${selected:+,}nvidia"; fi
    if [[ -z "${selected}" ]]; then
      GPU_REASON="no supported GPU found (expected AMD/Intel render nodes or an NVIDIA device)"
      return 1
    fi
  else
    selected="${request}"
  fi
  for vendor in amd intel; do
    if [[ ",${selected}," == *",${vendor},"* && " ${vendors[*]} " != *" ${vendor} "* ]]; then
      GPU_REASON="no ${vendor} GPU render node found under /dev/dri; check the host driver"
      return 1
    fi
  done
  if [[ ",${selected}," == *',nvidia,'* ]]; then gpu_check_nvidia || return 1; fi
  for node in "${!nodes[@]}"; do
    vendor="${vendors[$node]}"
    if [[ "${vendor}" != nvidia && ",${selected}," == *",${vendor},"* ]]; then
      GPU_DEVICES+=("${nodes[$node]}")
    fi
  done
  if [[ ",${selected}," == *',amd,'* ]] && gpu_device_exists /dev/kfd; then
    GPU_DEVICES+=(/dev/kfd)
  fi
  GPU_MODE="${selected}"
  GPU_REASON="device access configured; application GPU libraries are still required"
  if [[ ",${selected}," == *',amd,'* ]] && ! gpu_device_exists /dev/kfd; then
    GPU_REASON="AMD rendering available; /dev/kfd is missing, so ROCm compute is unavailable"
  fi
}

container_gpu_mode() {
  local mode
  mode="$(docker inspect --format '{{index .Config.Labels "io.infrasecture.mycodex.gpu"}}' \
    "${CONTAINER_NAME}" 2>/dev/null)" || return 1
  case "${mode}" in ''|'<no value>') printf 'none\n' ;; *) printf '%s\n' "${mode}" ;; esac
}

gpu_status_badge() {
  local mode
  mode="$(normalize_gpu_request "$1")" || mode=unknown
  case "${mode}" in
    none) printf 'GPU:off\n' ;;
    auto|unknown) printf 'GPU:?\n' ;;
    *) printf 'GPU:%s\n' "${mode^^}" ;;
  esac
}

guard_existing_gpu() {
  local current option
  [[ "${GPU_OPTION_SPECIFIED}" == 1 ]] || return 0
  container_exists || return 0
  current="$(container_gpu_mode)" || die "cannot inspect existing GPU access; no container was changed"
  [[ "${GPU_REQUEST}" != "${current}" ]] || return 0
  # --gpu on an existing GPU-enabled container reuses its established devices.
  if [[ "${GPU_REQUEST}" == auto && "${current}" != none ]]; then return 0; fi
  option="--gpu=${GPU_REQUEST}"
  [[ "${GPU_REQUEST}" != none ]] || option=--no-gpu
  [[ "${GPU_REQUEST}" != auto ]] || option=--gpu
  die "container ${CONTAINER_NAME} has GPU mode ${current}; changing GPU access requires 'myCodex down', then 'myCodex ${option}' (starts and attaches)"
}

# Reproduce the saved device set, not a fresh auto-detection. This also runs
# before automatic stopped-image updates; failure keeps the original container.
restore_gpu() {
  local saved node vendor normalized
  GPU_DEVICES=()
  GPU_MODE="$(container_gpu_mode)" || { GPU_REASON="cannot inspect existing GPU access"; return 1; }
  [[ "${GPU_MODE}" != none ]] || return 0
  normalized="$(normalize_gpu_request "${GPU_MODE}")" || normalized=""
  if [[ "${normalized}" != "${GPU_MODE}" || "${GPU_MODE}" == auto ]]; then
    GPU_REASON="unrecognized saved GPU configuration"
    return 1
  fi
  gpu_local_host || return 1
  if [[ ",${GPU_MODE}," == *',nvidia,'* ]]; then gpu_check_nvidia || return 1; fi
  saved="$(docker inspect --format '{{index .Config.Labels "io.infrasecture.mycodex.gpu.devices"}}' \
    "${CONTAINER_NAME}" 2>/dev/null)" || return 1
  [[ "${saved}" != '<no value>' ]] || saved=""
  if [[ -n "${saved}" && ! "${saved}" =~ ^/dev/(kfd|dri/renderD[0-9]+)(,/dev/(kfd|dri/renderD[0-9]+))*$ ]]; then
    GPU_REASON="unrecognized saved GPU device list"
    return 1
  fi
  IFS=, read -r -a GPU_DEVICES <<<"${saved}"
  for node in "${GPU_DEVICES[@]}"; do
    GPU_REASON="saved GPU device ${node} is unavailable or no longer matches its vendor"
    [[ "${node}" == /dev/kfd || "${node}" =~ ^/dev/dri/renderD[0-9]+$ ]] || return 1
    gpu_device_exists "${node}" || return 1
    if [[ "${node}" == /dev/kfd ]]; then vendor=amd
    else vendor="$(gpu_vendor_for_node "${node}")" || return 1; fi
    [[ "${vendor}" != nvidia && ",${GPU_MODE}," == *",${vendor},"* ]] || return 1
  done
  for vendor in amd intel; do
    if [[ ",${GPU_MODE}," == *",${vendor},"* ]]; then
      saved=""
      for node in "${GPU_DEVICES[@]}"; do
        if [[ "${node}" != /dev/kfd && "$(gpu_vendor_for_node "${node}")" == "${vendor}" ]]; then saved=1; fi
      done
      if [[ -z "${saved}" ]]; then GPU_REASON="saved ${vendor} render devices are missing"; return 1; fi
    fi
  done
  GPU_REASON="preserving established GPU access"
}

write_gpu_override() {
  local node gid devices
  local -a permission_nodes
  [[ "${GPU_MODE}" != none ]] || return 0
  GPU_HOST_GROUPS="${HOST_GROUPS}"
  permission_nodes=("${GPU_DEVICES[@]}")
  if [[ ",${GPU_MODE}," == *',nvidia,'* ]]; then
    for node in /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
      if gpu_device_exists "${node}"; then permission_nodes+=("${node}"); fi
    done
  fi
  for node in "${permission_nodes[@]}"; do
    gid="$(gpu_device_group "${node}")" || { GPU_REASON="cannot read GPU device permissions: ${node}"; return 1; }
    if [[ -n "${gid}" && ",${GPU_HOST_GROUPS}," != *",${gid}:"* ]]; then
      GPU_HOST_GROUPS+=",${gid}:gpu-${gid}"
    fi
  done
  devices="$(IFS=,; printf '%s' "${GPU_DEVICES[*]}")"
  if [[ -z "${GPU_COMPOSE_FILE}" ]]; then GPU_COMPOSE_FILE="$(mktemp -t mycodex-gpu.XXXXXX.yaml)" || return 1; fi
  {
    printf 'services:\n  codex:\n    labels:\n'
    printf '      io.infrasecture.mycodex.gpu: %s\n' "$(yaml_quote "${GPU_MODE}")"
    printf '      io.infrasecture.mycodex.gpu.devices: %s\n' "$(yaml_quote "${devices}")"
    if [[ ${#GPU_DEVICES[@]} -gt 0 ]]; then
      printf '    devices:\n'
      for node in "${GPU_DEVICES[@]}"; do printf '      - %s\n' "$(yaml_quote "${node}:${node}:rw")"; done
    fi
    if [[ ",${GPU_MODE}," == *',nvidia,'* ]]; then
      cat <<'EOF'
    environment:
      NVIDIA_DRIVER_CAPABILITIES: compute,utility,graphics,video,display
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
EOF
    fi
  } >"${GPU_COMPOSE_FILE}"
}

prepare_gpu() {
  [[ -z "${GPU_COMPOSE_FILE}" ]] || return 0
  guard_existing_gpu
  if container_exists; then
    restore_gpu || die "cannot preserve GPU access: ${GPU_REASON}"
  else
    detect_gpu || die "--gpu unavailable: ${GPU_REASON}"
  fi
  write_gpu_override || die "cannot prepare GPU access: ${GPU_REASON}"
  if [[ "${GPU_MODE}" != none ]]; then startup_notice "GPU ${GPU_MODE}: ${GPU_REASON}"; fi
}
