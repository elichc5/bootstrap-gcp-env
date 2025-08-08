# GCP Environment Provisioner

A Bash script to bootstrap and manage foundational GCP resources, including VPC networks, subnets, firewall rules, Compute Engine instances, and cleanup operations. This tool provides a consistent, idempotent way to set up and tear down base infrastructure components across projects.

---

## Features

- **Interactive Setup**: Prompts for project selection, network configuration, subnet definitions, firewall rules, and VM provisioning options.
- **Resource Idempotency**: Detects existing resources and skips creation to avoid duplicates.
- **Logging and Feedback**: Uses colored messages (INFO, OK, WARNING, ERROR) for clear real-time status reporting.
- **Automated Teardown**: Generates a `teardown.sh` script to delete all resources created by the setup.

---

## Use Cases

- Rapidly bootstrap new GCP projects with standard network and compute configurations.
- Create development, testing, or staging environments with minimal manual effort.
- Ensure consistent setup across teams by using a single, version-controlled script.

---

## Prerequisites

- **Google Cloud SDK** (`gcloud`) installed and authenticated.
- **IAM Roles**: Your account needs at least:
  - `roles/compute.networkAdmin`
  - `roles/compute.instanceAdmin.v1`
  - `roles/iam.securityAdmin`
- **Bash** (v4+) in a Unix-like shell.

---

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/<your-username>/<repository-name>.git
   cd <repository-name>
   ```
2. Make the script executable:
   ```bash
   chmod +x bootstrap-gcp-env.sh
   ```

---

## Usage

```bash
./bootstrap-gcp-env.sh
```

You will be guided through:

1. Selecting or creating a **GCP Project**
2. Configuring a **VPC Network** (new or existing)
3. Defining **Subnets** (names, regions, CIDR ranges)
4. Setting up **Firewall Rules** for internal and SSH access
5. Provisioning **VM Instances** (count, names, zones)

Once complete, run:

```bash
./teardown.sh
```

to clean up all resources created by the script.

---

## Script Name

The current filename is `deploy_env.sh`. Consider renaming to reflect its generic scope:

- `bootstrap-gcp-env.sh`
- `gcp-environment-provisioner.sh`
- `gcp-infra-bootstrap.sh`

---

## Contributing

Contributions and feedback are welcome. Please open an issue or submit a pull request.

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

---

## Author

Francisco Chaná © \$(date +%Y)

