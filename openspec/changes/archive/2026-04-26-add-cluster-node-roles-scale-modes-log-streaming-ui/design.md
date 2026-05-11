## Overview
The new control plane is a Dockerized web application deployed on the OpenStack bastion. It acts as a thin orchestration and observability layer over existing Slurm, OpenStack, and Kolla-Ansible flows.

The application has three responsibilities:
1. Aggregate node state from Slurm and OpenStack into a unified inventory.
2. Execute expand/shrink operations in either batch mode or direct mode.
3. Capture, stream, and retain execution logs for operator review.

## Architecture
### Deployment boundary
The application runs on the OpenStack bastion because:
- OpenStack credentials already need to exist there for compute deletion flows.
- Bastion-side Docker deployment patterns already exist in the repository.
- The bastion can SSH to the Slurm headnode, which is where Slurm commands and the existing Singularity-based flow run.

### Data sources
The backend merges three data sources:
- Slurm live state from the headnode over SSH using commands such as `sinfo`, `scontrol show nodes`, `squeue`, and `sacct`.
- OpenStack live state on the bastion using `openstack compute service list` and `openstack network agent list` with existing credentials.
- Terraform outputs as auxiliary metadata for node names, IPs, and bootstrap hints.

### Role classification
Each node is normalized into a single record with fields such as:
- node_name
- ip
- slurm_state
- openstack_compute_registered
- role
- notes

Classification rules:
- If the node is registered as an OpenStack compute service, classify it as OpenStack compute.
- If the node is present in Slurm and not registered as nova-compute, classify it as Slurm worker.
- If both systems report active ownership or one side appears stale, classify it as transition/conflict and surface a warning.

## Execution model
### Shared orchestration contract
Both batch mode and direct mode must reuse the same logical pipeline:
1. Determine target nodes.
2. Run pre hook playbook.
3. Run payload script (`add_computes.sh` or `del_computes.sh`) inside the same Singularity/Kolla environment assumptions used today.
4. Run post hook playbook.

The direct mode must not bypass these hooks. It only bypasses Slurm partition allocation.

### Batch mode
Batch mode remains the default. The backend submits the equivalent of:
- expand: `make PARTITION=<x> OCCUPY_NUM=<n> singularity-sbatch-expand`
- shrink: `make PARTITION=<x> JOB_ID=<id> singularity-sbatch-shrink`

The backend records the returned Slurm job id and monitors execution with `sacct`.

### Direct mode
Direct mode is used when operators cannot rely on available Slurm partition capacity. In this mode, the backend connects to the Slurm headnode over SSH and runs the same logical sequence directly, including the same bind mounts, image path assumptions, credential requirements, and playbook hooks currently embedded in `job_scripts/submit.sh`.

Direct mode requires:
- Explicit operator confirmation.
- Stronger warnings in the UI.
- Serialized execution or conflict checks so incompatible operations do not overlap.

### Shrink targeting
Shrink supports two entry modes:
- Job-id-based targeting.
- Node-selection-based targeting.

Node-selection mode resolves selected nodes back to a valid current workflow target. If selections are ambiguous, mixed-origin, or unsafe, the action is rejected with a clear explanation.

## Logging and observability
### Batch-mode logs
Batch expand/shrink executions should write stdout/stderr to deterministic files on the headnode. The backend uses Slurm job id plus known log-path conventions to fetch and tail logs over SSH while separately polling `sacct` for state.

### Direct-mode logs
Direct executions write their streamed stdout/stderr into application-managed log files on the bastion or a known remote log path copied back to the bastion. The UI uses the same log viewer for both modes.

### UI log experience
The UI exposes:
- Live follow mode while an execution is running.
- Replay for completed operations.
- Associated metadata such as execution mode, job id if present, target nodes, and terminal state.

## UI structure
The initial UI contains three operator-facing areas:
- Node inventory: shows node state, inferred role, and mismatch indicators.
- Operations panel: supports expand and shrink with execution-mode choice.
- History and logs: shows current and past operations with inline log viewing.

## Safety and failure handling
The backend validates:
- Partition exists when batch mode is selected.
- Requested node count is valid.
- Shrink job id exists when provided.
- Selected nodes can be resolved safely.
- Singularity image and required mounts exist.
- OpenStack credential files are present.
- Log files are readable.
- Direct mode does not overlap with conflicting direct operations.

Failures must be surfaced as actionable operator messages rather than raw command failures.

## Non-goals
This change does not:
- Provision or destroy Terraform infrastructure from the UI.
- Replace the existing Kolla-Ansible or Slurm scripts.
- Introduce a general-purpose cloud management portal.
- Change the underlying compute expansion lifecycle beyond adding a direct execution fallback.