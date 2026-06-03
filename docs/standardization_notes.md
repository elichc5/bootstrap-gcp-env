# Standardization Notes

## Current script assessment

### Legacy bootstrap

The original interactive bootstrap was a good starting point, but it was retired
from the canonical flow because of the following issues:

- It is interactive, which makes repeatable automation hard.
- Resource names like `iap-ssh` and `allow-internal` are global within a project and can collide.
- Subnet creation is not idempotent.
- VM creation is not idempotent.
- It does not enable APIs or validate prerequisites.
- The generated teardown has a parsing bug for subnets stored as `name:region:cidr`; it extracts `region:cidr` instead of only `region`.
- The final summary prints escaped variable names for project and network instead of their values.

### `provision_classic_vpn_route_based.sh`

This is already close to the desired standard:

- config-driven
- idempotent
- validates overlapping CIDRs
- generates teardown
- now supports optional validation

## Standard going forward

Canonical scripts:

- `provision_environment.sh`
- `provision_classic_vpn_route_based.sh`

Canonical config examples:

- `environment.env.example`
- `classic_vpn_route_based.env.example`

Generated artifacts:

- `generated/teardown_environment.sh`
- `generated/teardown_classic_vpn_route_based.sh`
- `generated/validate_classic_vpn_route_based.sh`

## Recommended workflow

1. Copy `environment.env.example` to a working env file and adjust values.
2. Run `./provision_environment.sh <env-file>`.
3. Copy `classic_vpn_route_based.env.example` to a working env file and adjust values.
4. Run `./provision_classic_vpn_route_based.sh <env-file>`.
5. Optionally run `./generated/validate_classic_vpn_route_based.sh`.
6. Destroy with the matching generated teardown scripts.
