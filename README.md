# GCP Hybrid Lab Automation

This repository standardizes two parts of the lab lifecycle:

1. Base environment provisioning
2. Classic VPN provisioning and validation

The current canonical scripts are:

- [`provision_environment.sh`](provision_environment.sh)
- [`provision_classic_vpn_route_based.sh`](provision_classic_vpn_route_based.sh)

Reference notes about the standardization are in
[`docs/standardization_notes.md`](docs/standardization_notes.md).

## Repository layout

- `provision_environment.sh`: canonical bootstrap for the isolated base environments
- `environment.env.example`: example config for the environment bootstrap
- `provision_classic_vpn_route_based.sh`: canonical Classic VPN route-based automation
- `classic_vpn_route_based.env.example`: example config for the VPN layer
- `generated/`: runtime-generated teardown and validation scripts, ignored by Git

## Standard workflow

Provision the base environment:

```bash
cp environment.env.example environment.env
./provision_environment.sh environment.env
```

Provision the VPN:

```bash
cp classic_vpn_route_based.env.example classic_vpn_route_based.env
./provision_classic_vpn_route_based.sh classic_vpn_route_based.env
```

Optional validation:

```bash
./generated/validate_classic_vpn_route_based.sh
```

Destroy resources:

```bash
./generated/teardown_environment.sh
./generated/teardown_classic_vpn_route_based.sh
```

## Notes

- The base environment and VPN scripts are idempotent-oriented and config-driven.
- VPN validation can be generated always and executed only when desired.
- Generated env files and runtime artifacts are intentionally ignored by Git.
