#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

################################################################################
# provision_classic_vpn_route_based.sh
# Description : Provisions a Classic VPN with static routes between two
#               existing GCP projects and VPC networks.
# Usage       : ./provision_classic_vpn_route_based.sh [config-file]
# Notes       : This script complements bootstrap_gcp_env.sh by assuming that
#               the base VPCs and subnets already exist.
################################################################################

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  ./provision_classic_vpn_route_based.sh [config-file]

Expected configuration variables:
  CONNECTION_NAME
  LEFT_SITE_NAME
  LEFT_PROJECT_ID
  LEFT_NETWORK
  LEFT_REGION
  LEFT_LOCAL_CIDRS
  RIGHT_SITE_NAME
  RIGHT_PROJECT_ID
  RIGHT_NETWORK
  RIGHT_REGION
  RIGHT_LOCAL_CIDRS
  VPN_SHARED_SECRET

Optional variables:
  GCP_ACCOUNT
  IKE_VERSION              (default: 2)
  ROUTE_PRIORITY           (default: 1000)
  VPN_FW_RULES             (default: all)
  RUN_POST_VALIDATION      (default: false)
  LEFT_TEST_VM_NAME
  LEFT_TEST_VM_ZONE
  LEFT_PING_TARGETS        (comma-separated IPs)
  RIGHT_TEST_VM_NAME
  RIGHT_TEST_VM_ZONE
  RIGHT_PING_TARGETS       (comma-separated IPs)

Example:
  ./provision_classic_vpn_route_based.sh classic_vpn.env
EOF
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

load_config() {
  local config_file="${1:-}"
  if [[ -n "$config_file" ]]; then
    [[ -f "$config_file" ]] || log_error "Config file not found: $config_file"
    # shellcheck disable=SC1090
    source "$config_file"
    log_ok "Loaded configuration from $config_file"
  fi
}

require_commands() {
  command -v gcloud >/dev/null 2>&1 || log_error "gcloud is required"
  command -v python3 >/dev/null 2>&1 || log_error "python3 is required"
}

ensure_generated_dir() {
  mkdir -p generated
}

require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || log_error "Required variable is not set: $name"
  done
}

init_defaults() {
  IKE_VERSION="${IKE_VERSION:-2}"
  ROUTE_PRIORITY="${ROUTE_PRIORITY:-1000}"
  VPN_FW_RULES="${VPN_FW_RULES:-all}"
  RUN_POST_VALIDATION="${RUN_POST_VALIDATION:-false}"

  LEFT_GATEWAY_NAME="${LEFT_GATEWAY_NAME:-vpn-${LEFT_SITE_NAME}-${CONNECTION_NAME}-gw}"
  RIGHT_GATEWAY_NAME="${RIGHT_GATEWAY_NAME:-vpn-${RIGHT_SITE_NAME}-${CONNECTION_NAME}-gw}"

  LEFT_ADDRESS_NAME="${LEFT_ADDRESS_NAME:-ip-${LEFT_SITE_NAME}-${CONNECTION_NAME}-vpn}"
  RIGHT_ADDRESS_NAME="${RIGHT_ADDRESS_NAME:-ip-${RIGHT_SITE_NAME}-${CONNECTION_NAME}-vpn}"

  LEFT_TUNNEL_NAME="${LEFT_TUNNEL_NAME:-tun-${LEFT_SITE_NAME}-to-${RIGHT_SITE_NAME}-01}"
  RIGHT_TUNNEL_NAME="${RIGHT_TUNNEL_NAME:-tun-${RIGHT_SITE_NAME}-to-${LEFT_SITE_NAME}-01}"

  LEFT_FW_NAME="${LEFT_FW_NAME:-fw-${LEFT_SITE_NAME}-from-${RIGHT_SITE_NAME}-vpn}"
  RIGHT_FW_NAME="${RIGHT_FW_NAME:-fw-${RIGHT_SITE_NAME}-from-${LEFT_SITE_NAME}-vpn}"

  LEFT_FR_ESP_NAME="${LEFT_FR_ESP_NAME:-fr-${LEFT_GATEWAY_NAME}-esp}"
  LEFT_FR_UDP500_NAME="${LEFT_FR_UDP500_NAME:-fr-${LEFT_GATEWAY_NAME}-udp500}"
  LEFT_FR_UDP4500_NAME="${LEFT_FR_UDP4500_NAME:-fr-${LEFT_GATEWAY_NAME}-udp4500}"

  RIGHT_FR_ESP_NAME="${RIGHT_FR_ESP_NAME:-fr-${RIGHT_GATEWAY_NAME}-esp}"
  RIGHT_FR_UDP500_NAME="${RIGHT_FR_UDP500_NAME:-fr-${RIGHT_GATEWAY_NAME}-udp500}"
  RIGHT_FR_UDP4500_NAME="${RIGHT_FR_UDP4500_NAME:-fr-${RIGHT_GATEWAY_NAME}-udp4500}"
}

is_true() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_account() {
  if [[ -z "${GCP_ACCOUNT:-}" ]]; then
    return 0
  fi

  local active_account
  active_account="$(gcloud config get-value account 2>/dev/null || true)"
  if [[ "$active_account" != "$GCP_ACCOUNT" ]]; then
    log_info "Setting active gcloud account to $GCP_ACCOUNT"
    gcloud config set account "$GCP_ACCOUNT" >/dev/null
  fi
  log_ok "Using gcloud account $GCP_ACCOUNT"
}

csv_to_lines() {
  local csv="$1"
  local raw=()
  local item

  IFS=',' read -r -a raw <<< "$csv"
  for item in "${raw[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}

join_by() {
  local delimiter="$1"
  shift
  local first=1
  local value

  for value in "$@"; do
    if (( first )); then
      printf '%s' "$value"
      first=0
    else
      printf '%s%s' "$delimiter" "$value"
    fi
  done
}

validate_no_overlap() {
  python3 - "$LEFT_LOCAL_CIDRS" "$RIGHT_LOCAL_CIDRS" <<'PY'
import ipaddress
import sys

left = [ipaddress.ip_network(v.strip(), strict=False) for v in sys.argv[1].split(",") if v.strip()]
right = [ipaddress.ip_network(v.strip(), strict=False) for v in sys.argv[2].split(",") if v.strip()]

for left_net in left:
    for right_net in right:
        if left_net.overlaps(right_net):
            print(f"Overlapping CIDRs detected: {left_net} and {right_net}", file=sys.stderr)
            sys.exit(1)

print("CIDR validation passed")
PY
  log_ok "Validated that local CIDRs do not overlap"
}

ensure_compute_api() {
  local project="$1"
  if gcloud services list --enabled --project="$project" --filter="config.name:compute.googleapis.com" --format="value(config.name)" | grep -qx "compute.googleapis.com"; then
    log_info "Compute API already enabled for $project"
  else
    log_info "Enabling Compute API for $project"
    gcloud services enable compute.googleapis.com --project="$project"
    log_ok "Enabled Compute API for $project"
  fi
}

ensure_network_exists() {
  local project="$1" network="$2"
  gcloud compute networks describe "$network" --project="$project" >/dev/null 2>&1 \
    || log_error "Network $network was not found in project $project"
  log_ok "Validated network $network in project $project"
}

ensure_target_vpn_gateway() {
  local project="$1" region="$2" network="$3" gateway="$4"
  if gcloud compute target-vpn-gateways describe "$gateway" --project="$project" --region="$region" >/dev/null 2>&1; then
    log_info "Target VPN gateway $gateway already exists in $project"
  else
    log_info "Creating target VPN gateway $gateway in $project"
    gcloud compute target-vpn-gateways create "$gateway" \
      --project="$project" \
      --network="$network" \
      --region="$region"
    log_ok "Created target VPN gateway $gateway"
  fi
}

ensure_address() {
  local project="$1" region="$2" address_name="$3"
  if gcloud compute addresses describe "$address_name" --project="$project" --region="$region" >/dev/null 2>&1; then
    log_info "Static IP $address_name already exists in $project"
  else
    log_info "Creating static IP $address_name in $project"
    gcloud compute addresses create "$address_name" \
      --project="$project" \
      --region="$region"
    log_ok "Created static IP $address_name"
  fi
}

get_address_ip() {
  local project="$1" region="$2" address_name="$3"
  gcloud compute addresses describe "$address_name" \
    --project="$project" \
    --region="$region" \
    --format='value(address)'
}

ensure_forwarding_rule() {
  local project="$1" region="$2" name="$3" address_name="$4" gateway="$5" protocol="$6" ports="${7:-}"
  if gcloud compute forwarding-rules describe "$name" --project="$project" --region="$region" >/dev/null 2>&1; then
    log_info "Forwarding rule $name already exists in $project"
  else
    log_info "Creating forwarding rule $name in $project"
    if [[ -n "$ports" ]]; then
      gcloud compute forwarding-rules create "$name" \
        --project="$project" \
        --region="$region" \
        --load-balancing-scheme=EXTERNAL \
        --network-tier=PREMIUM \
        --ip-protocol="$protocol" \
        --ports="$ports" \
        --address="$address_name" \
        --target-vpn-gateway="$gateway"
    else
      gcloud compute forwarding-rules create "$name" \
        --project="$project" \
        --region="$region" \
        --load-balancing-scheme=EXTERNAL \
        --network-tier=PREMIUM \
        --ip-protocol="$protocol" \
        --address="$address_name" \
        --target-vpn-gateway="$gateway"
    fi
    log_ok "Created forwarding rule $name"
  fi
}

ensure_vpn_tunnel() {
  local project="$1" region="$2" tunnel="$3" peer_ip="$4" gateway="$5"
  if gcloud compute vpn-tunnels describe "$tunnel" --project="$project" --region="$region" >/dev/null 2>&1; then
    log_info "VPN tunnel $tunnel already exists in $project"
  else
    log_info "Creating VPN tunnel $tunnel in $project"
    gcloud compute vpn-tunnels create "$tunnel" \
      --project="$project" \
      --region="$region" \
      --peer-address="$peer_ip" \
      --ike-version="$IKE_VERSION" \
      --shared-secret="$VPN_SHARED_SECRET" \
      --local-traffic-selector=0.0.0.0/0 \
      --remote-traffic-selector=0.0.0.0/0 \
      --target-vpn-gateway="$gateway"
    log_ok "Created VPN tunnel $tunnel"
  fi
}

ensure_route() {
  local project="$1" network="$2" region="$3" route_name="$4" destination_range="$5" tunnel="$6" priority="$7"
  if gcloud compute routes describe "$route_name" --project="$project" >/dev/null 2>&1; then
    log_info "Route $route_name already exists in $project"
  else
    log_info "Creating route $route_name for $destination_range in $project"
    gcloud compute routes create "$route_name" \
      --project="$project" \
      --network="$network" \
      --destination-range="$destination_range" \
      --priority="$priority" \
      --next-hop-vpn-tunnel="$tunnel" \
      --next-hop-vpn-tunnel-region="$region"
    log_ok "Created route $route_name"
  fi
}

ensure_firewall_rule() {
  local project="$1" network="$2" name="$3" source_ranges="$4" description="$5"
  if gcloud compute firewall-rules describe "$name" --project="$project" >/dev/null 2>&1; then
    log_info "Firewall rule $name already exists in $project"
  else
    log_info "Creating firewall rule $name in $project"
    gcloud compute firewall-rules create "$name" \
      --project="$project" \
      --network="$network" \
      --direction=INGRESS \
      --priority=1000 \
      --action=ALLOW \
      --rules="$VPN_FW_RULES" \
      --source-ranges="$source_ranges" \
      --description="$description"
    log_ok "Created firewall rule $name"
  fi
}

ensure_routes_for_side() {
  local project="$1" network="$2" region="$3" tunnel="$4" local_site="$5" remote_site="$6"
  shift 6
  local remote_cidrs=("$@")
  local index=1
  local route_name
  local cidr

  for cidr in "${remote_cidrs[@]}"; do
    route_name="$(printf 'rt-%s-to-%s-%02d' "$local_site" "$remote_site" "$index")"
    ensure_route "$project" "$network" "$region" "$route_name" "$cidr" "$tunnel" "$ROUTE_PRIORITY"
    ((index++))
  done
}

generate_teardown() {
  local left_remote_csv="$1"
  local right_remote_csv="$2"

  ensure_generated_dir
  cat > generated/teardown_classic_vpn_route_based.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
IFS=\$'\n\t'

${GCP_ACCOUNT:+gcloud config set account ${GCP_ACCOUNT} >/dev/null}

gcloud compute routes delete $(route_names_for_teardown "$LEFT_SITE_NAME" "$RIGHT_SITE_NAME" "$left_remote_csv") --project=${LEFT_PROJECT_ID} --quiet || true
gcloud compute routes delete $(route_names_for_teardown "$RIGHT_SITE_NAME" "$LEFT_SITE_NAME" "$right_remote_csv") --project=${RIGHT_PROJECT_ID} --quiet || true

gcloud compute vpn-tunnels delete ${LEFT_TUNNEL_NAME} --project=${LEFT_PROJECT_ID} --region=${LEFT_REGION} --quiet || true
gcloud compute vpn-tunnels delete ${RIGHT_TUNNEL_NAME} --project=${RIGHT_PROJECT_ID} --region=${RIGHT_REGION} --quiet || true

gcloud compute firewall-rules delete ${LEFT_FW_NAME} --project=${LEFT_PROJECT_ID} --quiet || true
gcloud compute firewall-rules delete ${RIGHT_FW_NAME} --project=${RIGHT_PROJECT_ID} --quiet || true

gcloud compute forwarding-rules delete ${LEFT_FR_ESP_NAME} ${LEFT_FR_UDP500_NAME} ${LEFT_FR_UDP4500_NAME} --project=${LEFT_PROJECT_ID} --region=${LEFT_REGION} --quiet || true
gcloud compute forwarding-rules delete ${RIGHT_FR_ESP_NAME} ${RIGHT_FR_UDP500_NAME} ${RIGHT_FR_UDP4500_NAME} --project=${RIGHT_PROJECT_ID} --region=${RIGHT_REGION} --quiet || true

gcloud compute addresses delete ${LEFT_ADDRESS_NAME} --project=${LEFT_PROJECT_ID} --region=${LEFT_REGION} --quiet || true
gcloud compute addresses delete ${RIGHT_ADDRESS_NAME} --project=${RIGHT_PROJECT_ID} --region=${RIGHT_REGION} --quiet || true

gcloud compute target-vpn-gateways delete ${LEFT_GATEWAY_NAME} --project=${LEFT_PROJECT_ID} --region=${LEFT_REGION} --quiet || true
gcloud compute target-vpn-gateways delete ${RIGHT_GATEWAY_NAME} --project=${RIGHT_PROJECT_ID} --region=${RIGHT_REGION} --quiet || true
EOF
  chmod +x generated/teardown_classic_vpn_route_based.sh
  log_ok "Generated generated/teardown_classic_vpn_route_based.sh"
}

route_names_for_teardown() {
  local local_site="$1" remote_site="$2" csv="$3"
  local index=1
  local names=()
  local _cidr

  while IFS= read -r _cidr; do
    names+=("$(printf 'rt-%s-to-%s-%02d' "$local_site" "$remote_site" "$index")")
    ((index++))
  done < <(csv_to_lines "$csv")
  join_by ' ' "${names[@]}"
}

print_summary() {
  cat <<EOF

Classic VPN route-based configuration completed (or verified):

  Left side
    Project       : ${CYAN}${LEFT_PROJECT_ID}${NC}
    Network       : ${CYAN}${LEFT_NETWORK}${NC}
    Gateway       : ${CYAN}${LEFT_GATEWAY_NAME}${NC}
    Gateway IP    : ${CYAN}${LEFT_GATEWAY_IP}${NC}
    Tunnel        : ${CYAN}${LEFT_TUNNEL_NAME}${NC}
    Firewall rule : ${CYAN}${LEFT_FW_NAME}${NC}
    Routes        : ${CYAN}${RIGHT_LOCAL_CIDRS}${NC}

  Right side
    Project       : ${CYAN}${RIGHT_PROJECT_ID}${NC}
    Network       : ${CYAN}${RIGHT_NETWORK}${NC}
    Gateway       : ${CYAN}${RIGHT_GATEWAY_NAME}${NC}
    Gateway IP    : ${CYAN}${RIGHT_GATEWAY_IP}${NC}
    Tunnel        : ${CYAN}${RIGHT_TUNNEL_NAME}${NC}
    Firewall rule : ${CYAN}${RIGHT_FW_NAME}${NC}
    Routes        : ${CYAN}${LEFT_LOCAL_CIDRS}${NC}
EOF
}

validate_tunnel_status() {
  local project="$1" region="$2" tunnel="$3"
  gcloud compute vpn-tunnels describe "$tunnel" \
    --project="$project" \
    --region="$region" \
    --format='value(status)'
}

run_ping_validation() {
  local project="$1" zone="$2" vm_name="$3" targets_csv="$4" label="$5"
  local targets=()
  local target

  if [[ -z "$vm_name" || -z "$zone" || -z "$targets_csv" ]]; then
    log_warn "Skipping VM validation for $label because VM name, zone, or targets were not provided"
    return 0
  fi

  while IFS= read -r target; do
    targets+=("$target")
  done < <(csv_to_lines "$targets_csv")

  for target in "${targets[@]}"; do
    log_info "Validating connectivity from $vm_name to $target over IAP"
    gcloud compute ssh "$vm_name" \
      --project="$project" \
      --zone="$zone" \
      --tunnel-through-iap \
      --quiet \
      --command="ping -c 3 $target"
    log_ok "Connectivity validation succeeded from $vm_name to $target"
  done
}

generate_validation_script() {
  ensure_generated_dir
  cat > generated/validate_classic_vpn_route_based.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
IFS=\$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "\${BLUE}[INFO]\${NC}  \$*"; }
log_ok()    { echo -e "\${GREEN}[OK]\${NC}    \$*"; }
log_warn()  { echo -e "\${YELLOW}[WARN]\${NC}  \$*"; }
log_error() { echo -e "\${RED}[ERROR]\${NC} \$*"; exit 1; }

${GCP_ACCOUNT:+gcloud config set account ${GCP_ACCOUNT} >/dev/null}

LEFT_STATUS=\$(gcloud compute vpn-tunnels describe ${LEFT_TUNNEL_NAME} --project=${LEFT_PROJECT_ID} --region=${LEFT_REGION} --format='value(status)')
RIGHT_STATUS=\$(gcloud compute vpn-tunnels describe ${RIGHT_TUNNEL_NAME} --project=${RIGHT_PROJECT_ID} --region=${RIGHT_REGION} --format='value(status)')

log_info "Left tunnel status: \$LEFT_STATUS"
log_info "Right tunnel status: \$RIGHT_STATUS"

[[ "\$LEFT_STATUS" == "ESTABLISHED" ]] || log_error "Left tunnel is not established"
[[ "\$RIGHT_STATUS" == "ESTABLISHED" ]] || log_error "Right tunnel is not established"

log_ok "Both VPN tunnels are established"
EOF

  if [[ -n "${LEFT_TEST_VM_NAME:-}" && -n "${LEFT_TEST_VM_ZONE:-}" && -n "${LEFT_PING_TARGETS:-}" ]]; then
    cat >> generated/validate_classic_vpn_route_based.sh <<EOF
log_info "Validating left-side VM reachability"
gcloud compute ssh ${LEFT_TEST_VM_NAME} \\
  --project=${LEFT_PROJECT_ID} \\
  --zone=${LEFT_TEST_VM_ZONE} \\
  --tunnel-through-iap \\
  --quiet \\
  --command="for ip in \$(printf '%s' '${LEFT_PING_TARGETS}' | tr ',' ' '); do ping -c 3 \\\$ip; done"
log_ok "Left-side VM reachability validation completed"
EOF
  fi

  if [[ -n "${RIGHT_TEST_VM_NAME:-}" && -n "${RIGHT_TEST_VM_ZONE:-}" && -n "${RIGHT_PING_TARGETS:-}" ]]; then
    cat >> generated/validate_classic_vpn_route_based.sh <<EOF
log_info "Validating right-side VM reachability"
gcloud compute ssh ${RIGHT_TEST_VM_NAME} \\
  --project=${RIGHT_PROJECT_ID} \\
  --zone=${RIGHT_TEST_VM_ZONE} \\
  --tunnel-through-iap \\
  --quiet \\
  --command="for ip in \$(printf '%s' '${RIGHT_PING_TARGETS}' | tr ',' ' '); do ping -c 3 \\\$ip; done"
log_ok "Right-side VM reachability validation completed"
EOF
  fi

  chmod +x generated/validate_classic_vpn_route_based.sh
  log_ok "Generated generated/validate_classic_vpn_route_based.sh"
}

run_post_validation() {
  local left_status right_status

  log_info "Running optional post-provision validation"
  left_status="$(validate_tunnel_status "$LEFT_PROJECT_ID" "$LEFT_REGION" "$LEFT_TUNNEL_NAME")"
  right_status="$(validate_tunnel_status "$RIGHT_PROJECT_ID" "$RIGHT_REGION" "$RIGHT_TUNNEL_NAME")"

  [[ "$left_status" == "ESTABLISHED" ]] || log_error "Left tunnel status is $left_status"
  [[ "$right_status" == "ESTABLISHED" ]] || log_error "Right tunnel status is $right_status"
  log_ok "Both tunnels are established"

  run_ping_validation "$LEFT_PROJECT_ID" "${LEFT_TEST_VM_ZONE:-}" "${LEFT_TEST_VM_NAME:-}" "${LEFT_PING_TARGETS:-}" "$LEFT_SITE_NAME"
  run_ping_validation "$RIGHT_PROJECT_ID" "${RIGHT_TEST_VM_ZONE:-}" "${RIGHT_TEST_VM_NAME:-}" "${RIGHT_PING_TARGETS:-}" "$RIGHT_SITE_NAME"
}

main() {
  local left_cidrs=()
  local right_cidrs=()
  local right_sources
  local left_sources

  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage && exit 0

  require_commands
  load_config "${1:-}"
  require_env \
    CONNECTION_NAME \
    LEFT_SITE_NAME \
    LEFT_PROJECT_ID \
    LEFT_NETWORK \
    LEFT_REGION \
    LEFT_LOCAL_CIDRS \
    RIGHT_SITE_NAME \
    RIGHT_PROJECT_ID \
    RIGHT_NETWORK \
    RIGHT_REGION \
    RIGHT_LOCAL_CIDRS \
    VPN_SHARED_SECRET

  init_defaults
  ensure_account
  validate_no_overlap

  while IFS= read -r cidr; do
    left_cidrs+=("$cidr")
  done < <(csv_to_lines "$LEFT_LOCAL_CIDRS")
  while IFS= read -r cidr; do
    right_cidrs+=("$cidr")
  done < <(csv_to_lines "$RIGHT_LOCAL_CIDRS")
  left_sources="$(join_by ',' "${left_cidrs[@]}")"
  right_sources="$(join_by ',' "${right_cidrs[@]}")"

  ensure_compute_api "$LEFT_PROJECT_ID"
  ensure_compute_api "$RIGHT_PROJECT_ID"
  ensure_network_exists "$LEFT_PROJECT_ID" "$LEFT_NETWORK"
  ensure_network_exists "$RIGHT_PROJECT_ID" "$RIGHT_NETWORK"

  ensure_target_vpn_gateway "$LEFT_PROJECT_ID" "$LEFT_REGION" "$LEFT_NETWORK" "$LEFT_GATEWAY_NAME"
  ensure_target_vpn_gateway "$RIGHT_PROJECT_ID" "$RIGHT_REGION" "$RIGHT_NETWORK" "$RIGHT_GATEWAY_NAME"

  ensure_address "$LEFT_PROJECT_ID" "$LEFT_REGION" "$LEFT_ADDRESS_NAME"
  ensure_address "$RIGHT_PROJECT_ID" "$RIGHT_REGION" "$RIGHT_ADDRESS_NAME"

  LEFT_GATEWAY_IP="$(get_address_ip "$LEFT_PROJECT_ID" "$LEFT_REGION" "$LEFT_ADDRESS_NAME")"
  RIGHT_GATEWAY_IP="$(get_address_ip "$RIGHT_PROJECT_ID" "$RIGHT_REGION" "$RIGHT_ADDRESS_NAME")"

  ensure_forwarding_rule "$LEFT_PROJECT_ID" "$LEFT_REGION" "$LEFT_FR_ESP_NAME" "$LEFT_ADDRESS_NAME" "$LEFT_GATEWAY_NAME" "ESP"
  ensure_forwarding_rule "$LEFT_PROJECT_ID" "$LEFT_REGION" "$LEFT_FR_UDP500_NAME" "$LEFT_ADDRESS_NAME" "$LEFT_GATEWAY_NAME" "UDP" "500"
  ensure_forwarding_rule "$LEFT_PROJECT_ID" "$LEFT_REGION" "$LEFT_FR_UDP4500_NAME" "$LEFT_ADDRESS_NAME" "$LEFT_GATEWAY_NAME" "UDP" "4500"

  ensure_forwarding_rule "$RIGHT_PROJECT_ID" "$RIGHT_REGION" "$RIGHT_FR_ESP_NAME" "$RIGHT_ADDRESS_NAME" "$RIGHT_GATEWAY_NAME" "ESP"
  ensure_forwarding_rule "$RIGHT_PROJECT_ID" "$RIGHT_REGION" "$RIGHT_FR_UDP500_NAME" "$RIGHT_ADDRESS_NAME" "$RIGHT_GATEWAY_NAME" "UDP" "500"
  ensure_forwarding_rule "$RIGHT_PROJECT_ID" "$RIGHT_REGION" "$RIGHT_FR_UDP4500_NAME" "$RIGHT_ADDRESS_NAME" "$RIGHT_GATEWAY_NAME" "UDP" "4500"

  ensure_vpn_tunnel "$LEFT_PROJECT_ID" "$LEFT_REGION" "$LEFT_TUNNEL_NAME" "$RIGHT_GATEWAY_IP" "$LEFT_GATEWAY_NAME"
  ensure_vpn_tunnel "$RIGHT_PROJECT_ID" "$RIGHT_REGION" "$RIGHT_TUNNEL_NAME" "$LEFT_GATEWAY_IP" "$RIGHT_GATEWAY_NAME"

  ensure_routes_for_side "$LEFT_PROJECT_ID" "$LEFT_NETWORK" "$LEFT_REGION" "$LEFT_TUNNEL_NAME" "$LEFT_SITE_NAME" "$RIGHT_SITE_NAME" "${right_cidrs[@]}"
  ensure_routes_for_side "$RIGHT_PROJECT_ID" "$RIGHT_NETWORK" "$RIGHT_REGION" "$RIGHT_TUNNEL_NAME" "$RIGHT_SITE_NAME" "$LEFT_SITE_NAME" "${left_cidrs[@]}"

  ensure_firewall_rule "$LEFT_PROJECT_ID" "$LEFT_NETWORK" "$LEFT_FW_NAME" "$right_sources" "Allow ingress from ${RIGHT_SITE_NAME} over Classic VPN"
  ensure_firewall_rule "$RIGHT_PROJECT_ID" "$RIGHT_NETWORK" "$RIGHT_FW_NAME" "$left_sources" "Allow ingress from ${LEFT_SITE_NAME} over Classic VPN"

  generate_teardown "$RIGHT_LOCAL_CIDRS" "$LEFT_LOCAL_CIDRS"
  generate_validation_script
  if is_true "$RUN_POST_VALIDATION"; then
    run_post_validation
  else
    log_info "Skipping post-validation. Run ./generated/validate_classic_vpn_route_based.sh whenever you want."
  fi
  print_summary
  log_ok "Classic VPN route-based provisioning completed"
}

main "$@"
