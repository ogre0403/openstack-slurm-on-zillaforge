## Why
Current cluster operations are split across Terraform, Slurm, and Kolla-Ansible command-line flows. Operators can provision OpenStack and Slurm clusters, then use Slurm jobs to expand or shrink OpenStack compute capacity, but there is no single UI that shows which nodes are currently acting as Slurm workers versus OpenStack computes. There is also no operator-friendly way to observe expand/shrink execution logs in real time.

In addition, the current expand/shrink flow depends on Slurm partition capacity because it is submitted as a Slurm job. When the partition is exhausted, operators need a controlled fallback that can run the same orchestration directly on the headnode without waiting for additional scheduler resources.

## What Changes
Add a Docker-deployed web control plane that runs on the OpenStack bastion and provides:
- A live node inventory view that combines Slurm and OpenStack state to show whether each node is acting as a Slurm worker or an OpenStack compute.
- Expand and shrink controls that support both batch job mode and direct mode.
- A unified execution history and log viewer for both Slurm job executions and direct executions.
- Safe shrink workflows that support both job-id-based targeting and node-selection-based targeting.

Batch mode remains the default and preserves the current `sbatch`-based workflow. Direct mode is an explicit fallback for cases where Slurm partition capacity is insufficient.

## Impact
This change creates a new operator-facing surface and a new bastion-side application deployment path. It does not replace Terraform provisioning, Kolla-Ansible logic, or the existing Slurm/Kolla scripts. Instead, it wraps the current automation with a consistent control plane, shared orchestration model, and improved observability.

Operators gain:
- Faster visibility into cluster role assignment.
- A safer way to trigger expand/shrink flows.
- Real-time execution feedback through logs.
- A controlled fallback path when scheduler-backed execution is unavailable.