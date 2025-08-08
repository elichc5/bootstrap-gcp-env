#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

################################################################################
# bootstrap-gcp-env.sh
# Description : Bootstraps a foundational GCP environment with VPC networks,
#               subnets, firewall rules, Compute Engine VMs, and teardown script.
# Author      : Francisco Chaná
# Date        : $(date +%Y-%m-%d)
# Version     : 2.3 (Standardized, English comments and prompts)
################################################################################

# --- Color Definitions for Logging ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Helper Functions ---
confirm() {
  read -rp "$1 [y/N]: " response
  [[ $response =~ ^[Yy] ]] || return 1
}

# --- Ensure Project is Set ---
ensure_project() {
  if [[ -z "${GCP_PROJECT:-}" ]]; then
    read -rp "Enter your GCP Project ID: " GCP_PROJECT
  fi
  gcloud config set project "$GCP_PROJECT"
  log_ok "Using project $GCP_PROJECT"
}

# --- Ensure VPC Network ---
ensure_network() {
  read -rp "Network action (1) Create new  (2) Use existing: " net_choice
  if [[ $net_choice -eq 1 ]]; then
    read -rp "Enter new network name: " NETWORK_NAME
    gcloud compute networks create "$NETWORK_NAME" \
      --subnet-mode=custom --bgp-routing-mode=regional --mtu=1460
    log_ok "Created network $NETWORK_NAME"
  else
    read -rp "Enter existing network name: " NETWORK_NAME
    log_info "Using existing network $NETWORK_NAME"
  fi
}

# --- Ensure Subnets ---
ensure_subnets() {
  SUBNET_NAMES=()
  while confirm "Add a subnet?"; do
    read -rp "  Subnet name: " name
    read -rp "  Region:      " region
    read -rp "  CIDR (e.g. 10.0.0.0/24): " cidr
    gcloud compute networks subnets create "$name" \
      --network="$NETWORK_NAME" --region="$region" --range="$cidr" --enable-private-ip-google-access
    SUBNET_NAMES+=("$name:$region:$cidr")
    log_ok "Created subnet $name in $region ($cidr)"
  done
}

# --- Ensure Firewall Rules ---
ensure_firewalls() {
  # SSH via IAP
  if ! gcloud compute firewall-rules describe iap-ssh &>/dev/null; then
    gcloud compute firewall-rules create iap-ssh \
      --network="$NETWORK_NAME" --action=allow --direction=INGRESS \
      --rules=tcp:22 --source-ranges=35.235.240.0/20 \
      --description="Allow SSH via Identity-Aware Proxy"
    log_ok "Firewall rule iap-ssh created"
  else
    log_info "Firewall rule iap-ssh already exists"
  fi
  # Allow internal traffic
  if ! gcloud compute firewall-rules describe allow-internal &>/dev/null; then
    gcloud compute firewall-rules create allow-internal \
      --network="$NETWORK_NAME" --action=allow --direction=INGRESS \
      --rules=all --source-ranges=10.0.0.0/8 \
      --description="Allow internal network communication"
    log_ok "Firewall rule allow-internal created"
  else
    log_info "Firewall rule allow-internal already exists"
  fi
}

# --- Ensure VM Instances ---
ensure_vms() {
  VM_LIST=()
  while confirm "Create a VM instance?"; do
    read -rp "  Instance name: " vm_name
    read -rp "  Zone:          " zone
    read -rp "  Subnet name:   " subnet
    gcloud compute instances create "$vm_name" \
      --zone="$zone" --network="$NETWORK_NAME" --subnet="$subnet" \
      --no-address --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring
    VM_LIST+=("$vm_name:$zone")
    log_ok "Created VM $vm_name in $zone"
  done
}

# --- Generate Teardown Script ---
generate_teardown() {
  cat > teardown.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
IFS=\$'\n\t'

# Teardown resources
EOF
  echo "# Delete VMs" >> teardown.sh
  for vm in "${VM_LIST[@]}"; do
    name=\${vm%%:*}; zone=\${vm##*:}
    echo "gcloud compute instances delete \$name --zone=\$zone --quiet" >> teardown.sh
  done
  echo "# Delete firewall rules" >> teardown.sh
  echo "gcloud compute firewall-rules delete iap-ssh allow-internal --quiet" >> teardown.sh
  echo "# Delete subnets" >> teardown.sh
  for sn in "${SUBNET_NAMES[@]}"; do
    name=\${sn%%:*}; region=\${sn#*:}
    echo "gcloud compute networks subnets delete \$name --region=\$region --quiet" >> teardown.sh
  done
  echo "# Delete network" >> teardown.sh
  echo "gcloud compute networks delete \$NETWORK_NAME --quiet" >> teardown.sh
  chmod +x teardown.sh
  log_ok "Generated teardown.sh"
}

# --- Main Execution Flow ---
main() {
  log_info "Starting environment bootstrap"
  ensure_project
  ensure_network
  ensure_subnets
  ensure_firewalls
  ensure_vms

  log_ok "--- Bootstrap Completed Successfully ---"
  echo "Summary of resources created:"
  echo "  Project : ${CYAN}\$GCP_PROJECT${NC}"
  echo "  Network : ${CYAN}\$NETWORK_NAME${NC}"
  echo "  Subnets : ${CYAN}${SUBNET_NAMES[*]}${NC}"
  echo "  VMs     : ${CYAN}${VM_LIST[*]}${NC}"

  generate_teardown
}

main
