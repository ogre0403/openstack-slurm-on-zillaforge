# Cluster Control Plane

A Docker-deployed web application for the OpenStack bastion that provides:

- **Node Inventory**: Live view combining Slurm and OpenStack state with role classification.
- **Expand/Shrink Operations**: Batch mode (default, via `sbatch`) and direct mode (fallback).
- **Execution History & Logs**: Real-time log streaming and completed-log replay.

## Prerequisites

- Docker and Docker Compose on the bastion host.
- SSH access from bastion to the Slurm headnode.
- OpenStack credentials (clouds.yaml) available on the bastion.
- The `resource_manage` project synced to the Slurm headnode.

## Quick Start

```bash
# 1. Copy and edit the config
cp config.yaml.example config.yaml

# 2. Set required environment variables
export SLURM_HEADNODE_HOST=192.168.95.X
export SLURM_HEADNODE_USER=cloud-user
export SSH_KEY_PATH=~/.ssh/id_rsa

# 3. Build and start
docker compose up -d --build

# 4. Access the UI
# Open http://<bastion-ip>:5000 in your browser
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `SLURM_HEADNODE_HOST` | (required) | IP or hostname of the Slurm headnode |
| `SLURM_HEADNODE_USER` | `cloud-user` | SSH user for headnode access |
| `SSH_KEY_PATH` | `~/.ssh/id_rsa` | Path to SSH private key on host |
| `OS_CLOUD` | `kolla-admin` | OpenStack cloud profile name |
| `OS_CLIENT_CONFIG_FILE` | `/etc/openstack/clouds.yaml` | Path to clouds.yaml on host |
| `PROJECT_DIR` | `/home/cloud-user/resource_manage` | Project root on headnode |
| `ROCKY_VER` | `9` | Rocky Linux version (8 or 9) |

## Architecture

The control plane runs on the bastion and communicates with:

- **Slurm headnode** (via SSH): Collects node state, submits jobs, streams logs.
- **OpenStack APIs** (local credentials): Queries compute services and network agents.

```
┌─────────────────────┐         SSH          ┌──────────────────┐
│  Bastion             │ ──────────────────── │  Slurm Headnode  │
│  ┌─────────────────┐ │                      │  - sinfo/squeue  │
│  │ Control Plane   │ │                      │  - sbatch/srun   │
│  │ (Docker)        │ │                      │  - Singularity   │
│  └─────────────────┘ │                      └──────────────────┘
│  ┌─────────────────┐ │
│  │ OpenStack CLI   │ │
│  │ (credentials)   │ │
│  └─────────────────┘ │
└─────────────────────┘
```

## Execution Modes

### Batch Mode (Default)
Submits expand/shrink as Slurm jobs via `sbatch`. This is the standard path
that reuses the existing `job_scripts/submit.sh` workflow.

### Direct Mode (Fallback)
Runs the same orchestration directly on the headnode via SSH when Slurm
partition capacity is unavailable. Requires explicit operator confirmation.

## Log Storage

- **Batch mode logs**: Stored on headnode at deterministic paths based on Slurm job ID.
- **Direct mode logs**: Stored in `/data/logs/` on the bastion.
- **Execution metadata**: Persisted in `/data/executions/` as JSON files.
