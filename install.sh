#!/usr/bin/env bash
set -uo pipefail

# Multi 3x-ui Docker Manager (All-in-One)
# - Install & manage multiple 3x-ui panels with Docker
# - Per-panel monthly quota (GB)
# - Quota monitor (manual/debug + cron mode)
# Tested on: Ubuntu/Debian (root required)

########################
#  Global variables    #
########################

BASE_DIR=""
COMPOSE_FILE=""
DOCKER_COMPOSE_CMD=""
SERVER_IP=""
META_FILE=""
SCRIPT_PATH=""
CRON_TAG="# MULTI_3XUI_QUOTA"
CRON_EXPR="*/5 * * * *"

########################
#  Helper functions    #
########################

color_green() { printf "\e[32m%s\e[0m\n" "$*"; }
color_red()   { printf "\e[31m%s\e[0m\n" "$*"; }
color_yellow(){ printf "\e[33m%s\e[0m\n" "$*"; }
pause()       { read -rp "Press Enter to continue..." _; }

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    color_red "Please run this script as root (sudo -i && bash multi-3xui.sh)"
    exit 1
  fi
}

detect_script_path() {
  SCRIPT_PATH="$(readlink -f "$0")"
}

detect_base_dir() {
  if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
    BASE_DIR="/var/snap/docker/common/3xui-multi"
  else
    BASE_DIR="/opt/3xui-multi"
  fi
  COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
  META_FILE="${BASE_DIR}/panels-meta.conf"
}

detect_docker_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
  elif docker-compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker-compose"
  else
    color_yellow "Docker Compose not found, attempting to install plugin (Debian/Ubuntu)..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y docker-compose-plugin
      if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
      else
        color_red "Failed to install docker-compose plugin automatically."
        exit 1
      fi
    else
      color_red "Unsupported OS for automatic docker-compose installation."
      exit 1
    fi
  fi
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    color_green "Docker is already installed."
    return
  fi

  color_yellow "Docker not found. Installing Docker using get.docker.com..."
  if ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y curl
    else
      color_red "curl is required to install Docker automatically."
      exit 1
    fi
  fi

  curl -fsSL https://get.docker.com | sh

  systemctl enable docker || true
  systemctl start docker || true

  if ! command -v docker >/dev/null 2>&1; then
    color_red "Docker installation failed."
    exit 1
  fi
  color_green "Docker installed successfully."
}

detect_server_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip=$(curl -4s https://ifconfig.me || curl -4s https://ipv4.icanhazip.com || true)
  fi
  if [[ -z "${ip}" ]]; then
    if command -v hostname >/dev/null 2>&1; then
      ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
  fi
  if [[ -z "${ip}" ]]; then
    ip="YOUR_SERVER_IP"
  fi
  SERVER_IP="${ip}"
}

ensure_dirs() {
  mkdir -p "${BASE_DIR}"
  cd "${BASE_DIR}"
}

print_header() {
  clear
  echo "========================================"
  echo "       Multi 3x-ui Docker Manager       "
  echo "========================================"
  echo "Base directory: ${BASE_DIR}"
  echo "Server IP     : ${SERVER_IP}"
  echo
}

########################
#  Meta (quota)        #
########################

load_meta() {
  if [[ -f "${META_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${META_FILE}"
  fi
}

set_meta() {
  local key="$1"
  local val="$2"
  mkdir -p "${BASE_DIR}"
  touch "${META_FILE}"
  if grep -q "^${key}=" "${META_FILE}" 2>/dev/null; then
    sed -i "s/^${key}=.*/${key}=${val}/" "${META_FILE}"
  else
    echo "${key}=${val}" >> "${META_FILE}"
  fi
}

########################
#  Core logic          #
########################

ask_int() {
  local prompt default value
  prompt="$1"
  default="$2"
  while true; do
    read -rp "${prompt} [default: ${default}]: " value
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      echo "$value"
      return
    else
      color_red "Please enter a valid integer."
    fi
  done
}

port_range_overlap() {
  local s1="$1" e1="$2" s2="$3" e2="$4"
  if (( s1 <= e2 && s2 <= e1 )); then
    return 0
  else
    return 1
  fi
}

generate_compose_initial() {
  print_header
  color_green "=== Initial multi-3x-ui setup ==="
  echo

  local num_panels
  num_panels=$(ask_int "How many panels do you want to create?" "2")

  declare -a PANEL_PORTS
  declare -a RANGE_STARTS
  declare -a RANGE_ENDS

  : > "${META_FILE}"

  cat > "${COMPOSE_FILE}" <<EOF
version: "3.8"

services:
EOF

  for (( i=1; i<=num_panels; i++ )); do
    echo
    color_yellow "--- Panel #${i} configuration ---"

    local default_panel_port=$((2020 + i - 1))
    local panel_port
    while true; do
      panel_port=$(ask_int "Panel #${i} web port (host)?" "${default_panel_port}")
      local conflict=0
      for p in "${PANEL_PORTS[@]:-}"; do
        if [[ "$panel_port" -eq "$p" ]]; then
          conflict=1
          break
        fi
      done
      if (( conflict == 1 )); then
        color_red "Port ${panel_port} already used by another panel. Choose another."
      else
        PANEL_PORTS+=("$panel_port")
        break
      fi
    done

    local default_start=$((10000 + (i-1)*100))
    local default_end=$((default_start + 99))
    local range_start range_end

    while true; do
      range_start=$(ask_int "Inbound port range START for panel #${i}?" "${default_start}")
      range_end=$(ask_int "Inbound port range END for panel #${i}?" "${default_end}")
      if (( range_start >= range_end )); then
        color_red "Start must be less than end."
        continue
      fi

      local overlap=0
      local idx
      for idx in "${!RANGE_STARTS[@]}"; do
        if port_range_overlap "$range_start" "$range_end" "${RANGE_STARTS[$idx]}" "${RANGE_ENDS[$idx]}"; then
          overlap=1
          break
        fi
      done

      if (( overlap == 1 )); then
        color_red "Port range ${range_start}-${range_end} overlaps with an existing panel range."
      else
        RANGE_STARTS+=("$range_start")
        RANGE_ENDS+=("$range_end")
        break
      fi
    done

    local quota_gb
    quota_gb=$(ask_int "Monthly quota for panel #${i} in GB (0 = unlimited)?" "0")

    mkdir -p "xui${i}/db" "xui${i}/cert"

    set_meta "PANEL_${i}_QUOTA_GB" "${quota_gb}"
    set_meta "PANEL_${i}_USED_GB" "0"
    set_meta "PANEL_${i}_USED_BYTES" "0"
    set_meta "PANEL_${i}_LAST_BYTES" "0"

    cat >> "${COMPOSE_FILE}" <<EOF

  xui${i}:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: xui_panel_${i}
    restart: unless-stopped
    tty: true
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
      XUI_ENABLE_FAIL2BAN: "true"
    volumes:
      - ./xui${i}/db:/etc/x-ui
      - ./xui${i}/cert:/root/cert
    ports:
      - "${panel_port}:2053"
      - "${range_start}-${range_end}:${range_start}-${range_end}"
EOF

  done

  color_green "docker-compose.yml generated at: ${COMPOSE_FILE}"
  echo
  color_green "Bringing up all panels with Docker..."
  ${DOCKER_COMPOSE_CMD} -f "${COMPOSE_FILE}" up -d
  color_green "Done. Use the following URLs:"
  for idx in "${!PANEL_PORTS[@]}"; do
    local n=$((idx+1))
    echo "  Panel #${n} => http://${SERVER_IP}:${PANEL_PORTS[$idx]}"
  done
  echo
  pause
}

get_existing_panels_count() {
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    echo 0
    return
  fi
  local count
  count=$(grep -E '^[[:space:]]+xui[0-9]+:' "${COMPOSE_FILE}" | wc -l || true)
  echo "$count"
}

add_new_panel() {
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    color_red "docker-compose.yml not found. Run initial installation first."
    pause
    return
  fi

  local existing
  existing=$(get_existing_panels_count)
  local new_index=$((existing + 1))

  print_header
  color_green "=== Add new panel (Panel #${new_index}) ==="
  echo

  declare -a PANEL_PORTS
  declare -a RANGE_STARTS
  declare -a RANGE_ENDS

  while IFS= read -r line; do
    local host_port
    host_port=$(echo "$line" | sed -E 's/.*"([0-9]+):2053".*/\1/' || true)
    if [[ -n "$host_port" ]]; then
      PANEL_PORTS+=("$host_port")
    fi
  done < <(grep -E '"[0-9]+:2053"' "${COMPOSE_FILE}" || true)

  while IFS= read -r line; do
    local left
    left=$(echo "$line" | sed -E 's/.*"([0-9]+-[0-9]+):.*/\1/' || true)
    if [[ -n "$left" ]]; then
      local s e
      s=$(echo "$left" | cut -d- -f1)
      e=$(echo "$left" | cut -d- -f2)
      RANGE_STARTS+=("$s")
      RANGE_ENDS+=("$e")
    fi
  done < <(grep -E '"[0-9]+-[0-9]+:[0-9]+-[0-9]+"' "${COMPOSE_FILE}" || true)

  local default_panel_port=$((2020 + new_index - 1))
  local panel_port
  while true; do
    panel_port=$(ask_int "Panel #${new_index} web port (host)?" "${default_panel_port}")
    local conflict=0
    for p in "${PANEL_PORTS[@]:-}"; do
      if [[ "$panel_port" -eq "$p" ]]; then
        conflict=1
        break
      fi
    done
    if (( conflict == 1 )); then
      color_red "Port ${panel_port} already used by another panel. Choose another."
    else
      break
    fi
  done

  local default_start=$((10000 + (new_index-1)*100))
  local default_end=$((default_start + 99))
  local range_start range_end
  while true; do
    range_start=$(ask_int "Inbound port range START for panel #${new_index}?" "${default_start}")
    range_end=$(ask_int "Inbound port range END for panel #${new_index}?" "${default_end}")
    if (( range_start >= range_end )); then
      color_red "Start must be less than end."
      continue
    fi
    local overlap=0
    local idx
    for idx in "${!RANGE_STARTS[@]}"; do
      if port_range_overlap "$range_start" "$range_end" "${RANGE_STARTS[$idx]}" "${RANGE_ENDS[$idx]}"; then
        overlap=1
        break
      fi
    done
    if (( overlap == 1 )); then
      color_red "Port range ${range_start}-${range_end} overlaps with an existing panel range."
    else
      break
    fi
  done

  local quota_gb
  quota_gb=$(ask_int "Monthly quota for panel #${new_index} in GB (0 = unlimited)?" "0")

  mkdir -p "xui${new_index}/db" "xui${new_index}/cert"

  set_meta "PANEL_${new_index}_QUOTA_GB" "${quota_gb}"
  set_meta "PANEL_${new_index}_USED_GB" "0"
  set_meta "PANEL_${new_index}_USED_BYTES" "0"
  set_meta "PANEL_${new_index}_LAST_BYTES" "0"

  cat >> "${COMPOSE_FILE}" <<EOF

  xui${new_index}:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: xui_panel_${new_index}
    restart: unless-stopped
    tty: true
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
      XUI_ENABLE_FAIL2BAN: "true"
    volumes:
      - ./xui${new_index}/db:/etc/x-ui
      - ./xui${new_index}/cert:/root/cert
    ports:
      - "${panel_port}:2053"
      - "${range_start}-${range_end}:${range_start}-${range_end}"
EOF

  color_green "New panel #${new_index} appended to docker-compose.yml"
  ${DOCKER_COMPOSE_CMD} -f "${COMPOSE_FILE}" up -d
  color_green "Panel #${new_index} is starting..."
  echo "URL: http://${SERVER_IP}:${panel_port}"
  pause
}

reset_panel() {
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    color_red "docker-compose.yml not found. Nothing to reset."
    pause
    return
  fi

  local existing
  existing=$(get_existing_panels_count)
  if (( existing == 0 )); then
    color_red "No panels found."
    pause
    return
  fi

  print_header
  color_green "=== Reset a panel (clear its DB and restart) ==="
  echo "Existing panels: ${existing}"
  local idx
  idx=$(ask_int "Which panel number do you want to reset? (1-${existing})" "1")
  if (( idx < 1 || idx > existing )); then
    color_red "Invalid panel number."
    pause
    return
  fi

  read -rp "Are you sure you want to RESET panel #${idx}? This will wipe its DB. [y/N]: " yn
  yn=${yn:-N}
  if [[ ! "$yn" =~ ^[Yy]$ ]]; then
    color_yellow "Aborted."
    pause
    return
  fi

  docker stop "xui_panel_${idx}" >/dev/null 2>&1 || true

  rm -rf "xui${idx}/db"/*
  color_green "DB for panel #${idx} wiped."

  set_meta "PANEL_${idx}_USED_GB" "0"
  set_meta "PANEL_${idx}_USED_BYTES" "0"
  set_meta "PANEL_${idx}_LAST_BYTES" "0"

  ${DOCKER_COMPOSE_CMD} -f "${COMPOSE_FILE}" up -d
  color_green "Panel #${idx} restarted with fresh DB (default admin/admin)."
  pause
}

uninstall_all() {
  if [[ ! -d "${BASE_DIR}" ]]; then
    color_red "Base directory ${BASE_DIR} not found. Nothing to uninstall."
    pause
    return
  fi

  print_header
  color_red "=== WARNING: Full uninstall ==="
  echo "This will:"
  echo "  - Stop and remove all multi 3x-ui containers"
  echo "  - Remove docker-compose.yml and all xuiN data directories"
  echo

  read -rp "Are you sure you want to continue? [y/N]: " yn
  yn=${yn:-N}
  if [[ ! "$yn" =~ ^[Yy]$ ]]; then
    color_yellow "Aborted."
    pause
    return
  fi

  if [[ -f "${COMPOSE_FILE}" ]]; then
    ${DOCKER_COMPOSE_CMD} -f "${COMPOSE_FILE}" down || true
  fi

  rm -rf "${BASE_DIR}"

  color_green "All multi 3x-ui data and containers removed."
  pause
}

set_panel_quota_menu() {
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    color_red "docker-compose.yml not found. Nothing to configure."
    pause
    return
  fi

  local existing
  existing=$(get_existing_panels_count)
  if (( existing == 0 )); then
    color_red "No panels found."
    pause
    return
  fi

  load_meta
  print_header
  color_green "=== Set / change monthly quota for a panel ==="
  echo "Existing panels: ${existing}"
  local idx
  idx=$(ask_int "Which panel number do you want to configure? (1-${existing})" "1")
  if (( idx < 1 || idx > existing )); then
    color_red "Invalid panel number."
    pause
    return
  fi

  local quota_var="PANEL_${idx}_QUOTA_GB"
  local current_quota="${!quota_var:-0}"

  color_yellow "Current quota for panel #${idx}: ${current_quota} GB (0 = unlimited)"
  local new_quota
  new_quota=$(ask_int "New monthly quota in GB (0 = unlimited)?" "${current_quota}")
  set_meta "${quota_var}" "${new_quota}"
  color_green "Quota for panel #${idx} set to ${new_quota} GB."
  pause
}

reset_panel_usage_menu() {
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    color_red "docker-compose.yml not found. Nothing to configure."
    pause
    return
  fi

  local existing
  existing=$(get_existing_panels_count)
  if (( existing == 0 )); then
    color_red "No panels found."
    pause
    return
  fi

  load_meta
  print_header
  color_green "=== Reset usage for a panel (USED_GB/bytes -> 0) ==="
  echo "Existing panels: ${existing}"
  local idx
  idx=$(ask_int "Which panel number do you want to reset usage for? (1-${existing})" "1")
  if (( idx < 1 || idx > existing )); then
    color_red "Invalid panel number."
    pause
    return
  fi

  read -rp "Are you sure you want to reset usage for panel #${idx}? [y/N]: " yn
  yn=${yn:-N}
  if [[ ! "$yn" =~ ^[Yy]$ ]]; then
    color_yellow "Aborted."
    pause
    return
  fi

  set_meta "PANEL_${idx}_USED_GB" "0"
  set_meta "PANEL_${idx}_USED_BYTES" "0"
  set_meta "PANEL_${idx}_LAST_BYTES" "0"
  color_green "Usage for panel #${idx} reset to 0."

  # اگر کانتینر خاموش است، پیشنهاد روشن کردن بده
  local cname="xui_panel_${idx}"
  local cstatus
  cstatus=$(docker ps -a --filter "name=^${cname}$" --format '{{.Status}}')

  if [[ -n "$cstatus" ]] && ! docker ps --format '{{.Names}}' | grep -q "^${cname}$"; then
    echo
    color_yellow "Panel #${idx} (${cname}) is currently STOPPED."
    read -rp "Do you want to START this panel now? [y/N]: " yn2
    yn2=${yn2:-N}
    if [[ "$yn2" =~ ^[Yy]$ ]]; then
      if docker start "${cname}" >/dev/null 2>&1; then
        color_green "Panel #${idx} started successfully ✅"
      else
        color_red "Failed to start panel #${idx}. You can try manually: docker start ${cname}"
      fi
    else
      color_yellow "Panel remains stopped."
    fi
  fi

  pause
}

show_status() {
  print_header
  color_green "🧷 Docker containers (xui_panel_*)"
  echo

  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sed '1!{/xui_panel_/!d}'
  echo

  if [[ -f "${COMPOSE_FILE}" ]]; then
    color_green "📄 docker-compose.yml: ${COMPOSE_FILE}"
  else
    color_yellow "⚠️ docker-compose.yml not found."
  fi
  echo

  local existing
  existing=$(get_existing_panels_count)
  if (( existing > 0 )); then
    load_meta

    # جمع کردن پورت هر پنل
    declare -a PANEL_PORTS
    while IFS= read -r line; do
      local host_port
      host_port=$(echo "$line" | sed -E 's/.*"([0-9]+):2053".*/\1/' || true)
      if [[ -n "$host_port" ]]; then
        PANEL_PORTS+=("$host_port")
      fi
    done < <(grep -E '"[0-9]+:2053"' "${COMPOSE_FILE}" || true)

    echo "📊 Panels summary"
    echo "───────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    printf " %-4s │ %-22s │ %-12s │ %-16s │ %-10s\n"     "ID"     "URL"     "Quota"     "Used"     "Status"
    echo "──────────────────┼─────────────────────────────────────┼────────────────────┼────────────────────────┼────────────"

    local i
    for (( i=1; i<=existing; i++ )); do
      local port="${PANEL_PORTS[$((i-1))]:-?}"
      local quota_var="PANEL_${i}_QUOTA_GB"
      local used_gb_var="PANEL_${i}_USED_GB"
      local used_bytes_var="PANEL_${i}_USED_BYTES"

      local quota="${!quota_var:-0}"
      local used_gb="${!used_gb_var:-0}"
      local used_bytes="${!used_bytes_var:-0}"

      # نمایش quota
      local quota_text
      if [[ "${quota}" == "0" ]]; then
        quota_text="♾️  unlimited"
      else
        quota_text="${quota} GB"
      fi

      # نمایش used (GB + درصد)
      local used_text
      local percent="--"
      if [[ "${quota}" != "0" && "${quota}" != "" ]]; then
        local quota_bytes=$(( quota * 1024 * 1024 * 1024 ))
        if (( quota_bytes > 0 )); then
          percent=$(awk -v u="$used_bytes" -v q="$quota_bytes" 'BEGIN {printf "%.1f", (u/q)*100}')
        fi
      fi

      if [[ "${quota}" != "0" ]]; then
        used_text=$(printf "%.2f GB (%s%%)" "${used_gb}" "${percent}")
      else
        used_text=$(printf "%.2f GB" "${used_gb}")
      fi

      # وضعیت کانتینر
      local cname="xui_panel_${i}"
      local cstatus
      cstatus=$(docker ps --filter "name=^${cname}$" --format '{{.Status}}')
      if [[ -z "$cstatus" ]]; then
        cstatus="⛔ STOPPED"
      else
        cstatus="✅ RUNNING"
      fi

      local url="http://${SERVER_IP}:${port}"

      printf " %-4s │ %-22s │ %-12s │ %-16s │ %-10s\n" "#${i}" "${url}" "${quota_text}" "${used_text}" "${cstatus}"
    done

    echo "────────────────────────────────────────────────────────────────────────────"
  fi

  pause
}

########################
#  Quota Monitor       #
########################

human_to_bytes() {
  local v="$1"
  v="${v// /}"
  local num unit power
  if [[ "$v" =~ ^([0-9]*\.?[0-9]+)([kMGTPE]?B)$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    echo 0
    return
  fi
  case "$unit" in
    B)  power=0 ;;
    kB) power=1 ;;
    MB) power=2 ;;
    GB) power=3 ;;
    TB) power=4 ;;
    PB) power=5 ;;
    *)  power=0 ;;
  esac
  awk -v n="$num" -v p="$power" 'BEGIN {printf "%.0f", n * (1024^p)}'
}

quota_process_panel() {
  local idx="$1"
  local verbose="$2"

  local quota_var="PANEL_${idx}_QUOTA_GB"
  local used_bytes_var="PANEL_${idx}_USED_BYTES"
  local last_bytes_var="PANEL_${idx}_LAST_BYTES"
  local used_gb_var="PANEL_${idx}_USED_GB"

  local quota_gb="${!quota_var:-0}"
  local used_bytes="${!used_bytes_var:-0}"
  local last_bytes="${!last_bytes_var:-0}"

  local container="xui_panel_${idx}"
  if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
    [[ "$verbose" == "1" ]] && color_yellow "⚠️ Panel #${idx} (${container}) is not running, skipping."
    return
  fi

  local net_io
  net_io=$(docker stats --no-stream --format '{{.NetIO}}' "${container}" 2>/dev/null || echo "")
  if [[ -z "$net_io" ]]; then
    [[ "$verbose" == "1" ]] && color_yellow "⚠️ Panel #${idx}: unable to read NetIO."
    return
  fi

  local rx_str tx_str
  rx_str="${net_io%%/*}"
  tx_str="${net_io##*/}"

  rx_str="${rx_str// /}"
  tx_str="${tx_str// /}"

  local rx_bytes tx_bytes total_bytes
  rx_bytes=$(human_to_bytes "$rx_str")
  tx_bytes=$(human_to_bytes "$tx_str")
  total_bytes=$(( rx_bytes + tx_bytes ))

  if (( last_bytes == 0 )); then
    set_meta "${last_bytes_var}" "${total_bytes}"
    set_meta "${used_bytes_var}" "${used_bytes}"
    [[ "$verbose" == "1" ]] && echo "🟢 Panel #${idx}: first run, baseline set. Total=${total_bytes} bytes."
    return
  fi

  local delta=0
  if (( total_bytes >= last_bytes )); then
    delta=$((total_bytes - last_bytes))
  else
    # counters reset (container restarted)
    set_meta "${last_bytes_var}" "${total_bytes}"
    set_meta "${used_bytes_var}" "${used_bytes}"
    [[ "$verbose" == "1" ]] && echo "🔄 Panel #${idx}: docker counters reset, updating baseline only."
    return
  fi

  used_bytes=$((used_bytes + delta))

  set_meta "${last_bytes_var}" "${total_bytes}"
  set_meta "${used_bytes_var}" "${used_bytes}"

  # float GB with 2 decimals
  local used_gb
  used_gb=$(awk -v b="$used_bytes" 'BEGIN {printf "%.2f", b/(1024^3)}')
  set_meta "${used_gb_var}" "${used_gb}"

  if [[ "$verbose" == "1" ]]; then
    echo "📊 Panel #${idx} (${container}):"
    echo "  • NetIO now : ${net_io}"
    echo "  • Delta     : ${delta} bytes (~$(awk -v d="$delta" 'BEGIN {printf "%.3f", d/(1024^3)}') GB)"
    echo "  • Used total: ${used_bytes} bytes (~${used_gb} GB)"
  fi

  if [[ "${quota_gb}" != "0" ]]; then
    local quota_bytes=$(( quota_gb * 1024 * 1024 * 1024 ))
    if (( used_bytes >= quota_bytes )); then
      color_red "$(date) ⛔ Panel #${idx} exceeded quota: used ~${used_gb} GB / quota ${quota_gb} GB. Stopping container ${container}."
      docker stop "${container}" >/dev/null 2>&1 || true
    else
      [[ "$verbose" == "1" ]] && echo "  • Quota: ${quota_gb} GB (still under limit) ✅"
    fi
  else
    [[ "$verbose" == "1" ]] && echo "  • Quota: ♾️  unlimited"
  fi
}

quota_run() {
  local verbose="$1"

  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    [[ "$verbose" == "1" ]] && color_yellow "No docker-compose.yml at ${COMPOSE_FILE}, nothing to do."
    exit 0
  fi

  load_meta
  local existing
  existing=$(get_existing_panels_count)
  if (( existing == 0 )); then
    [[ "$verbose" == "1" ]] && color_yellow "No panels defined in compose."
    exit 0
  fi

  [[ "$verbose" == "1" ]] && echo "Running quota check for ${existing} panel(s)..."
  local i
  for (( i=1; i<=existing; i++ )); do
    quota_process_panel "$i" "$verbose"
    [[ "$verbose" == "1" ]] && echo "-----------------------------------------"
  done
}

quota_run_debug_menu() {
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    color_red "docker-compose.yml not found. Nothing to monitor."
    pause
    return
  fi

  local existing
  existing=$(get_existing_panels_count)
  if (( existing == 0 )); then
    color_red "No panels found."
    pause
    return
  fi

  load_meta

  # جمع کردن پورت هر پنل
  declare -a PANEL_PORTS
  while IFS= read -r line; do
    local host_port
    host_port=$(echo "$line" | sed -E 's/.*"([0-9]+):2053".*/\1/' || true)
    if [[ -n "$host_port" ]]; then
      PANEL_PORTS+=("$host_port")
    fi
  done < <(grep -E '"[0-9]+:2053"' "${COMPOSE_FILE}" || true)

  print_header
  echo "🧮 Live quota monitor (like docker stats)"
  echo "Ctrl + C For Exit."
  echo

  # هدر جدول
  printf " %-4s │ %-22s │ %-14s │ %-18s │ %-12s │ %-8s\n" "ID" "URL" "NetIO" "Used" "Quota" "Status"
  echo   "──────┼───────────────────────────────┼──────────────┼──────────────────┼──────────────┼──────────"

  # برای هر پنل یک خط خالی اولیه چاپ می‌کنیم
  local i
  for (( i=1; i<=existing; i++ )); do
    echo ""
  done

  # داخل این حلقه نمی‌خوایم set -e اسکریپت رو بترکونه
  set +e
  while true; do
    # ۱) آمار quota هر پنل را آپدیت کن (بدون خروجی – verbose=0)
    for (( i=1; i<=existing; i++ )); do
      quota_process_panel "$i" "0" || true
    done

    # ۲) meta را دوباره سورس کن تا اعداد جدید بیایند
    load_meta

    # ۳) کرسر را به ابتدای بلوک دیتا برگردان (فقط existing خط بالا برویم)
    printf "\033[%dA" "$existing"

    # ۴) برای هر پنل، یک خط جدید روی همان خط قبلی چاپ کن
    for (( i=1; i<=existing; i++ )); do
      local port="${PANEL_PORTS[$((i-1))]:-?}"
      local quota_var="PANEL_${i}_QUOTA_GB"
      local used_gb_var="PANEL_${i}_USED_GB"
      local used_bytes_var="PANEL_${i}_USED_BYTES"

      local quota="${!quota_var:-0}"
      local used_gb="${!used_gb_var:-0}"
      local used_bytes="${!used_bytes_var:-0}"

      # متن quota
      local quota_text
      if [[ "${quota}" == "0" ]]; then
        quota_text="♾️  unltd"
      else
        quota_text="${quota} GB"
      fi

      # متن used + درصد
      local used_text
      local percent="--"
      if [[ "${quota}" != "0" && "${quota}" != "" ]]; then
        local quota_bytes=$(( quota * 1024 * 1024 * 1024 ))
        if (( quota_bytes > 0 )); then
          percent=$(awk -v u="$used_bytes" -v q="$quota_bytes" 'BEGIN {printf "%.1f", (u/q)*100}')
        fi
      fi

      if [[ "${quota}" != "0" ]]; then
        used_text=$(printf "%.2f GB (%s%%)" "${used_gb}" "${percent}")
      else
        used_text=$(printf "%.2f GB" "${used_gb}")
      fi

      # وضعیت کانتینر
      local cname="xui_panel_${i}"
      local status_str
      if docker ps --format '{{.Names}}' | grep -q "^${cname}$" 2>/dev/null; then
        status_str="✅ RUN"
      else
        status_str="⛔ STOP"
      fi

      # NetIO فعلی (اگر docker stats خطا داد، فقط '-' می‌ذاریم)
      local net_io
      net_io=$(docker stats --no-stream --format '{{.NetIO}}' "${cname}" 2>/dev/null || echo "-")
      [[ -z "$net_io" ]] && net_io="-"

      local url="http://${SERVER_IP}:${port}"

      printf " %-4s │ %-22s │ %-14s │ %-18s │ %-12s │ %-8s\n" "#${i}" "${url}" "${net_io}" "${used_text}" "${quota_text}" "${status_str}"
    done

    sleep 1
  done
  # از نظر تئوری به اینجا نمی‌رسیم (Ctrl+C اسکریپت را قطع می‌کند)، ولی برای تمیزی:
  set -e
}

########################
#  Cron management     #
########################

is_cron_enabled() {
  crontab -l 2>/dev/null | grep -q "${CRON_TAG}" && return 0 || return 1
}

enable_quota_cron() {
  local cron_line="${CRON_EXPR} /bin/bash ${SCRIPT_PATH} --quota-cron >/dev/null 2>&1 ${CRON_TAG}"

  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -v "${CRON_TAG}" > "${tmp}" || true
  echo "${cron_line}" >> "${tmp}"
  crontab "${tmp}"
  rm -f "${tmp}"
  color_green "Quota cron enabled (every ${CRON_EXPR})."
  pause
}

disable_quota_cron() {
  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -v "${CRON_TAG}" > "${tmp}" || true
  crontab "${tmp}" || true
  rm -f "${tmp}"
  color_yellow "Quota cron disabled."
  pause
}

toggle_quota_cron_menu() {
  print_header
  if is_cron_enabled; then
    color_green "Quota cron is currently: ENABLED"
    echo
    read -rp "Do you want to DISABLE it? [y/N]: " yn
    yn=${yn:-N}
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      disable_quota_cron
    else
      color_yellow "No changes made."
      pause
    fi
  else
    color_yellow "Quota cron is currently: DISABLED"
    echo
    read -rp "Do you want to ENABLE it (every ${CRON_EXPR})? [y/N]: " yn
    yn=${yn:-N}
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      enable_quota_cron
    else
      color_yellow "No changes made."
      pause
    fi
  fi
}

########################
#  Menus / Entry       #
########################

main_menu() {
  while true; do
    print_header
    echo "📦 Panel Management"
    echo "  1) 🚀 Initial install / Rebuild multi 3x-ui"
    echo "  2) ➕ Add new panel"
    echo "  3) ♻️  Reset a panel (wipe DB and restart)"
    echo "  4) 🗑  Uninstall all panels (FULL REMOVE)"
    echo
    echo "📊 Quota & Status"
    echo "  5) 📋 Show status"
    echo "  6) 🎯 Set / change monthly quota for a panel"
    echo "  7) 🔁 Reset usage (USED_GB/bytes) for a panel"
    echo "  8) 🧮 Run quota check now (debug output)"
    echo "  9) ⏱  Enable/Disable automatic quota check (cron)"
    echo
    echo "  0) ❌ Exit"
    echo
    read -rp "Select an option: " choice
    case "$choice" in
      1) generate_compose_initial ;;
      2) add_new_panel ;;
      3) reset_panel ;;
      4) uninstall_all ;;
      5) show_status ;;
      6) set_panel_quota_menu ;;
      7) reset_panel_usage_menu ;;
      8) quota_run_debug_menu ;;
      9) toggle_quota_cron_menu ;;
      0) exit 0 ;;
      *) color_red "Invalid choice."; sleep 1 ;;
    esac
  done
}

########################
#  Entry point         #
########################

require_root
detect_script_path
install_docker_if_needed
detect_base_dir
ensure_dirs
detect_docker_compose_cmd
detect_server_ip
load_meta

# Cron mode (no output except errors/quota messages)
if [[ "${1-}" == "--quota-cron" ]]; then
  quota_run "0"
  exit 0
fi

# Interactive menu mode
main_menu
