#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

################################################################################
# provision_environment.sh
# Description : Provisions two isolated GCP environments from a config file.
# Usage       : ./provision_environment.sh [config-file]
# Notes       : This is the canonical environment bootstrap script for the lab.
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
  ./provision_environment.sh [config-file]

Required variables:
  LEFT_SITE_NAME
  LEFT_PROJECT_ID
  LEFT_NETWORK
  LEFT_REGION
  LEFT_ZONE
  LEFT_PRIMARY_SUBNET_NAME
  LEFT_PRIMARY_SUBNET_CIDR
  LEFT_SECONDARY_SUBNET_NAME
  LEFT_SECONDARY_SUBNET_CIDR
  LEFT_INTERNAL_SOURCE_RANGE
  LEFT_BASTION_VM_NAME
  LEFT_BASTION_VM_SUBNET
  LEFT_APP_VM_NAME
  LEFT_APP_VM_SUBNET
  RIGHT_SITE_NAME
  RIGHT_PROJECT_ID
  RIGHT_NETWORK
  RIGHT_REGION
  RIGHT_ZONE
  RIGHT_PRIMARY_SUBNET_NAME
  RIGHT_PRIMARY_SUBNET_CIDR
  RIGHT_SECONDARY_SUBNET_NAME
  RIGHT_SECONDARY_SUBNET_CIDR
  RIGHT_INTERNAL_SOURCE_RANGE
  RIGHT_BASTION_VM_NAME
  RIGHT_BASTION_VM_SUBNET
  RIGHT_APP_VM_NAME
  RIGHT_APP_VM_SUBNET

Optional variables:
  GCP_ACCOUNT
  MACHINE_TYPE             (default: e2-micro)
  IMAGE_FAMILY             (default: debian-12)
  IMAGE_PROJECT            (default: debian-cloud)
  BOOT_DISK_SIZE           (default: 20GB)
  BOOT_DISK_TYPE           (default: pd-balanced)
  IAP_SOURCE_RANGE         (default: 35.235.240.0/20)
  LABELS_BASE              (default: managed-by=codex,platform=hybrid-sim)

Example:
  ./provision_environment.sh environment.env
EOF
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

require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || log_error "Required variable is not set: $name"
  done
}

init_defaults() {
  MACHINE_TYPE="${MACHINE_TYPE:-e2-micro}"
  IMAGE_FAMILY="${IMAGE_FAMILY:-debian-12}"
  IMAGE_PROJECT="${IMAGE_PROJECT:-debian-cloud}"
  BOOT_DISK_SIZE="${BOOT_DISK_SIZE:-20GB}"
  BOOT_DISK_TYPE="${BOOT_DISK_TYPE:-pd-balanced}"
  IAP_SOURCE_RANGE="${IAP_SOURCE_RANGE:-35.235.240.0/20}"
  LABELS_BASE="${LABELS_BASE:-managed-by=codex,platform=hybrid-sim}"

  LEFT_IAP_FW_NAME="${LEFT_IAP_FW_NAME:-fw-${LEFT_SITE_NAME}-iap-ssh}"
  LEFT_INTERNAL_FW_NAME="${LEFT_INTERNAL_FW_NAME:-fw-${LEFT_SITE_NAME}-internal}"
  RIGHT_IAP_FW_NAME="${RIGHT_IAP_FW_NAME:-fw-${RIGHT_SITE_NAME}-iap-ssh}"
  RIGHT_INTERNAL_FW_NAME="${RIGHT_INTERNAL_FW_NAME:-fw-${RIGHT_SITE_NAME}-internal}"
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

ensure_network() {
  local project="$1" network="$2" region="$3"
  if gcloud compute networks describe "$network" --project="$project" >/dev/null 2>&1; then
    log_info "Network $network already exists in $project"
  else
    log_info "Creating network $network in $project"
    gcloud compute networks create "$network" \
      --project="$project" \
      --subnet-mode=custom \
      --bgp-routing-mode=regional \
      --mtu=1460
    log_ok "Created network $network in $region"
  fi
}

ensure_subnet() {
  local project="$1" region="$2" network="$3" subnet="$4" cidr="$5"
  if gcloud compute networks subnets describe "$subnet" --project="$project" --region="$region" >/dev/null 2>&1; then
    log_info "Subnet $subnet already exists in $project"
  else
    log_info "Creating subnet $subnet ($cidr) in $project"
    gcloud compute networks subnets create "$subnet" \
      --project="$project" \
      --network="$network" \
      --region="$region" \
      --range="$cidr" \
      --enable-private-ip-google-access
    log_ok "Created subnet $subnet"
  fi
}

ensure_firewall() {
  local project="$1" network="$2" name="$3" source_ranges="$4" rules="$5" description="$6"
  if gcloud compute firewall-rules describe "$name" --project="$project" >/dev/null 2>&1; then
    log_info "Firewall rule $name already exists in $project"
  else
    log_info "Creating firewall rule $name in $project"
    gcloud compute firewall-rules create "$name" \
      --project="$project" \
      --network="$network" \
      --action=allow \
      --direction=INGRESS \
      --source-ranges="$source_ranges" \
      --rules="$rules" \
      --description="$description"
    log_ok "Created firewall rule $name"
  fi
}

ensure_vm() {
  local project="$1" zone="$2" site="$3" name="$4" subnet="$5" role="$6" tags="$7"
  if gcloud compute instances describe "$name" --project="$project" --zone="$zone" >/dev/null 2>&1; then
    log_info "VM $name already exists in $project"
  else
    log_info "Creating VM $name in $project"
    gcloud compute instances create "$name" \
      --project="$project" \
      --zone="$zone" \
      --subnet="$subnet" \
      --machine-type="$MACHINE_TYPE" \
      --image-family="$IMAGE_FAMILY" \
      --image-project="$IMAGE_PROJECT" \
      --boot-disk-size="$BOOT_DISK_SIZE" \
      --boot-disk-type="$BOOT_DISK_TYPE" \
      --metadata=enable-oslogin=TRUE \
      --labels="${LABELS_BASE},site=${site},role=${role}" \
      --tags="$tags" \
      --no-address \
      --shielded-secure-boot \
      --shielded-vtpm \
      --shielded-integrity-monitoring
    log_ok "Created VM $name"
  fi
}

ensure_generated_dir() {
  mkdir -p generated
}

generate_teardown() {
  ensure_generated_dir
  cat > generated/teardown_environment.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
IFS=\$'\n\t'

${GCP_ACCOUNT:+gcloud config set account ${GCP_ACCOUNT} >/dev/null}

gcloud compute instances delete ${LEFT_BASTION_VM_NAME} ${LEFT_APP_VM_NAME} --project=${LEFT_PROJECT_ID} --zone=${LEFT_ZONE} --quiet || true
gcloud compute instances delete ${RIGHT_BASTION_VM_NAME} ${RIGHT_APP_VM_NAME} --project=${RIGHT_PROJECT_ID} --zone=${RIGHT_ZONE} --quiet || true

gcloud compute firewall-rules delete ${LEFT_IAP_FW_NAME} ${LEFT_INTERNAL_FW_NAME} --project=${LEFT_PROJECT_ID} --quiet || true
gcloud compute firewall-rules delete ${RIGHT_IAP_FW_NAME} ${RIGHT_INTERNAL_FW_NAME} --project=${RIGHT_PROJECT_ID} --quiet || true

gcloud compute networks subnets delete ${LEFT_SECONDARY_SUBNET_NAME} ${LEFT_PRIMARY_SUBNET_NAME} --project=${LEFT_PROJECT_ID} --region=${LEFT_REGION} --quiet || true
gcloud compute networks subnets delete ${RIGHT_SECONDARY_SUBNET_NAME} ${RIGHT_PRIMARY_SUBNET_NAME} --project=${RIGHT_PROJECT_ID} --region=${RIGHT_REGION} --quiet || true

gcloud compute networks delete ${LEFT_NETWORK} --project=${LEFT_PROJECT_ID} --quiet || true
gcloud compute networks delete ${RIGHT_NETWORK} --project=${RIGHT_PROJECT_ID} --quiet || true
EOF
  chmod +x generated/teardown_environment.sh
  log_ok "Generated generated/teardown_environment.sh"
}

print_summary() {
  cat <<EOF

Environment provisioning completed (or verified):

  Left side
    Project  : ${CYAN}${LEFT_PROJECT_ID}${NC}
    Network  : ${CYAN}${LEFT_NETWORK}${NC}
    Subnets  : ${CYAN}${LEFT_PRIMARY_SUBNET_NAME}, ${LEFT_SECONDARY_SUBNET_NAME}${NC}
    VMs      : ${CYAN}${LEFT_BASTION_VM_NAME}, ${LEFT_APP_VM_NAME}${NC}

  Right side
    Project  : ${CYAN}${RIGHT_PROJECT_ID}${NC}
    Network  : ${CYAN}${RIGHT_NETWORK}${NC}
    Subnets  : ${CYAN}${RIGHT_PRIMARY_SUBNET_NAME}, ${RIGHT_SECONDARY_SUBNET_NAME}${NC}
    VMs      : ${CYAN}${RIGHT_BASTION_VM_NAME}, ${RIGHT_APP_VM_NAME}${NC}
EOF
}

main() {
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage && exit 0

  load_config "${1:-}"
  require_env \
    LEFT_SITE_NAME LEFT_PROJECT_ID LEFT_NETWORK LEFT_REGION LEFT_ZONE \
    LEFT_PRIMARY_SUBNET_NAME LEFT_PRIMARY_SUBNET_CIDR LEFT_SECONDARY_SUBNET_NAME LEFT_SECONDARY_SUBNET_CIDR \
    LEFT_INTERNAL_SOURCE_RANGE LEFT_BASTION_VM_NAME LEFT_BASTION_VM_SUBNET LEFT_APP_VM_NAME LEFT_APP_VM_SUBNET \
    RIGHT_SITE_NAME RIGHT_PROJECT_ID RIGHT_NETWORK RIGHT_REGION RIGHT_ZONE \
    RIGHT_PRIMARY_SUBNET_NAME RIGHT_PRIMARY_SUBNET_CIDR RIGHT_SECONDARY_SUBNET_NAME RIGHT_SECONDARY_SUBNET_CIDR \
    RIGHT_INTERNAL_SOURCE_RANGE RIGHT_BASTION_VM_NAME RIGHT_BASTION_VM_SUBNET RIGHT_APP_VM_NAME RIGHT_APP_VM_SUBNET

  init_defaults
  ensure_account

  ensure_compute_api "$LEFT_PROJECT_ID"
  ensure_compute_api "$RIGHT_PROJECT_ID"

  ensure_network "$LEFT_PROJECT_ID" "$LEFT_NETWORK" "$LEFT_REGION"
  ensure_network "$RIGHT_PROJECT_ID" "$RIGHT_NETWORK" "$RIGHT_REGION"

  ensure_subnet "$LEFT_PROJECT_ID" "$LEFT_REGION" "$LEFT_NETWORK" "$LEFT_PRIMARY_SUBNET_NAME" "$LEFT_PRIMARY_SUBNET_CIDR"
  ensure_subnet "$LEFT_PROJECT_ID" "$LEFT_REGION" "$LEFT_NETWORK" "$LEFT_SECONDARY_SUBNET_NAME" "$LEFT_SECONDARY_SUBNET_CIDR"
  ensure_subnet "$RIGHT_PROJECT_ID" "$RIGHT_REGION" "$RIGHT_NETWORK" "$RIGHT_PRIMARY_SUBNET_NAME" "$RIGHT_PRIMARY_SUBNET_CIDR"
  ensure_subnet "$RIGHT_PROJECT_ID" "$RIGHT_REGION" "$RIGHT_NETWORK" "$RIGHT_SECONDARY_SUBNET_NAME" "$RIGHT_SECONDARY_SUBNET_CIDR"

  ensure_firewall "$LEFT_PROJECT_ID" "$LEFT_NETWORK" "$LEFT_IAP_FW_NAME" "$IAP_SOURCE_RANGE" "tcp:22" "Allow SSH over IAP into ${LEFT_SITE_NAME}"
  ensure_firewall "$LEFT_PROJECT_ID" "$LEFT_NETWORK" "$LEFT_INTERNAL_FW_NAME" "$LEFT_INTERNAL_SOURCE_RANGE" "tcp,udp,icmp" "Allow east-west traffic inside ${LEFT_SITE_NAME}"
  ensure_firewall "$RIGHT_PROJECT_ID" "$RIGHT_NETWORK" "$RIGHT_IAP_FW_NAME" "$IAP_SOURCE_RANGE" "tcp:22" "Allow SSH over IAP into ${RIGHT_SITE_NAME}"
  ensure_firewall "$RIGHT_PROJECT_ID" "$RIGHT_NETWORK" "$RIGHT_INTERNAL_FW_NAME" "$RIGHT_INTERNAL_SOURCE_RANGE" "tcp,udp,icmp" "Allow east-west traffic inside ${RIGHT_SITE_NAME}"

  ensure_vm "$LEFT_PROJECT_ID" "$LEFT_ZONE" "$LEFT_SITE_NAME" "$LEFT_BASTION_VM_NAME" "$LEFT_BASTION_VM_SUBNET" "bastion" "bastion,${LEFT_SITE_NAME}"
  ensure_vm "$LEFT_PROJECT_ID" "$LEFT_ZONE" "$LEFT_SITE_NAME" "$LEFT_APP_VM_NAME" "$LEFT_APP_VM_SUBNET" "app" "app,${LEFT_SITE_NAME}"
  ensure_vm "$RIGHT_PROJECT_ID" "$RIGHT_ZONE" "$RIGHT_SITE_NAME" "$RIGHT_BASTION_VM_NAME" "$RIGHT_BASTION_VM_SUBNET" "bastion" "bastion,${RIGHT_SITE_NAME}"
  ensure_vm "$RIGHT_PROJECT_ID" "$RIGHT_ZONE" "$RIGHT_SITE_NAME" "$RIGHT_APP_VM_NAME" "$RIGHT_APP_VM_SUBNET" "app" "app,${RIGHT_SITE_NAME}"

  generate_teardown
  print_summary
  log_ok "Environment provisioning completed"
}

main "$@"
