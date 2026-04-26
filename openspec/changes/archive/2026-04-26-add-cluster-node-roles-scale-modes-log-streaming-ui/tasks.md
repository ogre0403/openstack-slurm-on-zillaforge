## 1. Bastion-side app scaffold
- [x] Create a new bastion-deployed web app directory with Dockerfile, runtime config, and deployment instructions.
- [x] Define how the app receives OpenStack credentials, SSH access to the Slurm headnode, and persistent storage for execution history/log metadata.

## 2. Node inventory backend
- [x] Implement Slurm state collection over SSH from the headnode using `sinfo`, `scontrol`, `squeue`, and `sacct` as needed.
- [x] Implement OpenStack state collection on the bastion using existing credential files and CLI access.
- [x] Merge Slurm and OpenStack data into a normalized node inventory model with role classification and mismatch states.
- [x] Add tests or fixtures for pure Slurm worker, active OpenStack compute, and conflict/transition cases.

## 3. Shared expand/shrink orchestration
- [x] Implement a shared backend orchestration layer that models pre hook, payload execution, and post hook for both expand and shrink.
- [x] Reuse the current `job_scripts/submit.sh`, `add_computes.sh`, `del_computes.sh`, and related playbook contract as the source of truth for sequencing and runtime assumptions.
- [x] Add support for shrink by `JOB_ID` and shrink by selected nodes, including safe target resolution and rejection of ambiguous selections.

## 4. Batch mode support
- [x] Implement batch-mode execution by submitting the existing `make ... singularity-sbatch-expand` and `make ... singularity-sbatch-shrink` equivalents on the Slurm headnode.
- [x] Capture Slurm job ids, poll execution state with `sacct`, and persist the execution record.
- [x] Standardize batch-mode log file locations so logs can be deterministically located by job id.

## 5. Direct mode support
- [x] Implement direct-mode execution on the Slurm headnode as a controlled fallback when partition capacity is unavailable.
- [x] Ensure direct mode uses the same hooks, payload scripts, credentials, bind mounts, and image assumptions as the batch flow.
- [x] Add operator confirmations, warnings, and conflict prevention for concurrent direct operations.

## 6. Execution history and log viewer
- [x] Persist execution metadata including mode, job id when present, target nodes, status, and log path.
- [x] Implement live log streaming for batch mode via deterministic Slurm log files.
- [x] Implement live log streaming for direct mode via application-managed logs.
- [x] Add completed-log replay in the UI for both execution modes.

## 7. Frontend UI
- [x] Build a node inventory view showing node identity, Slurm state, OpenStack registration, inferred role, and mismatch indicators.
- [x] Build an operations panel for expand and shrink with execution-mode selection, batch as default and direct as fallback.
- [x] Build a history/log panel that displays operation metadata and inline follow-mode logs.
- [x] Add clear warnings around direct mode and unsafe shrink selections.

## 8. Verification and documentation
- [x] Verify batch expand from the UI matches the current `sbatch`-based behavior, including job id and logs.
- [x] Verify batch shrink from the UI matches the current `sbatch`-based behavior, including cleanup flow and logs.
- [x] Verify direct expand/shrink executes the same logical pre/payload/post sequence without relying on partition allocation.
- [x] Verify node-selection shrink safely resolves or rejects targets in both modes.
- [x] Verify completed logs remain accessible after execution ends.
- [x] Update repository documentation to describe deployment, credentials, batch/direct execution behavior, and log storage conventions.