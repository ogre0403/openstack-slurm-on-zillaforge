"""Shared expand/shrink orchestration layer.

Models the pre-hook → payload → post-hook pipeline for both batch and
direct execution modes. Reuses the existing job_scripts/submit.sh,
add_computes.sh, del_computes.sh, and playbook contracts.
"""

from __future__ import annotations

import logging
import threading
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable

from app.config import get_config
from app.services.execution_store import (
    create_execution,
    update_execution,
)
from app.services.slurm_collector import get_job_nodes, get_job_state
from app.services.ssh_client import get_ssh_client

logger = logging.getLogger(__name__)

# Lock to prevent concurrent direct-mode operations
_direct_mode_lock = threading.Lock()


class ExecutionMode(str, Enum):
    BATCH = "batch"
    DIRECT = "direct"


class OperationType(str, Enum):
    EXPAND = "expand"
    SHRINK = "shrink"


@dataclass
class OperationRequest:
    """Validated request for an expand or shrink operation."""

    operation: OperationType
    mode: ExecutionMode
    partition: str = "all"
    occupy_num: int = 1
    job_id: str | None = None
    selected_nodes: list[str] = field(default_factory=list)

    def validate(self) -> list[str]:
        """Return validation errors."""
        errors = []
        if not self.partition:
            errors.append("Partition is required")
        if self.operation == OperationType.EXPAND:
            if self.mode == ExecutionMode.DIRECT and not self.selected_nodes:
                errors.append(
                    "Direct expand requires selected_nodes from Node Inventory"
                )
            if self.mode == ExecutionMode.BATCH and self.occupy_num < 1:
                errors.append("occupy_num must be >= 1")
        if self.operation == OperationType.SHRINK:
            if not self.job_id and not self.selected_nodes:
                errors.append(
                    "Shrink requires either job_id or selected_nodes"
                )
            if self.job_id and self.selected_nodes:
                errors.append(
                    "Provide either job_id or selected_nodes, not both"
                )
        return errors


def _build_singularity_bind_args(config) -> str:
    """Build the Singularity bind mount arguments matching submit.sh."""
    return (
        f"-B {config.project.project_dir}/kolla-ansible/etc/kolla/:/etc/kolla "
        f"-B {config.project.project_dir}/kolla-ansible/etc/openstack/:/etc/openstack "
        f"-B {config.project.project_dir}/playbook:/playbook"
    )


def _build_singularity_exec_prefix(config) -> str:
    """Build the Singularity exec command prefix."""
    binds = _build_singularity_bind_args(config)
    return f"singularity exec {binds} {config.project.sif_path}"


def resolve_shrink_targets(
    job_id: str | None, selected_nodes: list[str]
) -> list[str]:
    """Resolve shrink target nodes from either job_id or selected_nodes.

    For job_id: uses sacct to find the nodes allocated to that expand job.
    For selected_nodes: validates that the nodes exist in the current Slurm
    inventory and are in a safe state for removal.

    Raises ValueError if targets cannot be resolved safely.
    """
    if job_id:
        nodes = get_job_nodes(job_id)
        if not nodes:
            raise ValueError(
                f"Could not resolve nodes for job {job_id}. "
                f"Job may not exist or has no allocated nodes."
            )
        return nodes

    if selected_nodes:
        # Validate selected nodes exist in Slurm
        from app.services.slurm_collector import collect_slurm_nodes

        slurm_nodes = {n.name for n in collect_slurm_nodes()}
        unknown = set(selected_nodes) - slurm_nodes
        if unknown:
            raise ValueError(
                f"Selected nodes not found in Slurm: {', '.join(sorted(unknown))}"
            )

        # Check for mixed-origin nodes (some are OpenStack compute, some are not)
        from app.services.openstack_collector import get_compute_hosts

        os_hosts = get_compute_hosts()
        os_selected = set(selected_nodes) & os_hosts
        non_os_selected = set(selected_nodes) - os_hosts

        if os_selected and non_os_selected:
            raise ValueError(
                f"Mixed selection: {', '.join(sorted(os_selected))} are OpenStack "
                f"computes but {', '.join(sorted(non_os_selected))} are not. "
                f"Shrink all selected nodes or refine your selection."
            )

        if not os_selected:
            raise ValueError(
                f"None of the selected nodes are registered as OpenStack computes. "
                f"Nothing to shrink."
            )

        return list(selected_nodes)

    raise ValueError("No shrink targets specified")


def execute_expand(
    mode: str = "batch",
    partition: str = "all",
    occupy_num: int = 1,
    selected_nodes: list[str] | None = None,
) -> dict:
    """Execute an expand operation.

    Returns the execution record as a dict.
    """
    req = OperationRequest(
        operation=OperationType.EXPAND,
        mode=ExecutionMode(mode),
        partition=partition,
        occupy_num=occupy_num,
        selected_nodes=selected_nodes or [],
    )

    errors = req.validate()
    if errors:
        raise ValueError("; ".join(errors))

    config = get_config()

    target_nodes = req.selected_nodes if req.mode == ExecutionMode.DIRECT else []

    # Create execution record
    execution = create_execution(
        operation="expand",
        mode=mode,
        partition=partition,
        target_nodes=target_nodes,
        occupy_num=occupy_num,
    )

    logger.info(
        "execute_expand: mode=%s partition=%s occupy_num=%d selected_nodes=%s execution_id=%s",
        mode, partition, occupy_num, req.selected_nodes, execution["id"],
    )

    if req.mode == ExecutionMode.BATCH:
        _execute_batch_expand(execution, config, req)
    else:
        _execute_direct_expand(execution, config, req)

    return execution


def execute_shrink(
    mode: str = "batch",
    partition: str = "all",
    job_id: str | None = None,
    selected_nodes: list[str] | None = None,
) -> dict:
    """Execute a shrink operation.

    Returns the execution record as a dict.
    """
    req = OperationRequest(
        operation=OperationType.SHRINK,
        mode=ExecutionMode(mode),
        partition=partition,
        job_id=job_id,
        selected_nodes=selected_nodes or [],
    )

    errors = req.validate()
    if errors:
        raise ValueError("; ".join(errors))

    # Resolve target nodes
    try:
        target_nodes = resolve_shrink_targets(req.job_id, req.selected_nodes)
    except ValueError as e:
        raise ValueError(f"Target resolution failed: {e}")

    config = get_config()

    execution = create_execution(
        operation="shrink",
        mode=mode,
        partition=partition,
        target_nodes=target_nodes,
        job_id=job_id,
    )

    logger.info(
        "execute_shrink: mode=%s partition=%s job_id=%s target_nodes=%s execution_id=%s",
        mode, partition, job_id, target_nodes, execution["id"],
    )

    if req.mode == ExecutionMode.BATCH:
        _execute_batch_shrink(execution, config, req)
    else:
        _execute_direct_shrink(execution, config, req, target_nodes)

    return execution


def _execute_batch_expand(execution: dict, config, req: OperationRequest):
    """Submit expand as a Slurm batch job via sbatch."""
    ssh = get_ssh_client()
    project_dir = config.project.project_dir
    log_dir = f"{project_dir}/logs"

    # Submit submit.sh as the sbatch script (not via --wrap) so that
    # submit.sh runs on the host where scontrol/sacct are available.
    # This mirrors the Makefile singularity-sbatch-expand target.
    sbatch_cmd = (
        f"mkdir -p {log_dir} && "
        f"sbatch -J expand "
        f"--partition={req.partition} "
        f"--nodes={req.occupy_num} "
        f"--output={log_dir}/expand-%j.out "
        f"--error={log_dir}/expand-%j.err "
        f"--export=ALL,PROJECT_DIR={project_dir},PAYLOAD_DIR={config.project.payload_dir},ROCKY_VER={config.project.rocky_ver} "
        f"{config.project.submit_script} add"
    )

    logger.info("batch_expand [%s] submitting sbatch command: %s", execution["id"], sbatch_cmd)
    exit_code, stdout, stderr = ssh.run(sbatch_cmd)

    if exit_code != 0:
        logger.error("batch_expand [%s] sbatch failed (exit %d): %s", execution["id"], exit_code, stderr)
        update_execution(execution["id"], status="failed", error=stderr)
        raise RuntimeError(f"sbatch expand failed: {stderr}")

    # Parse "Submitted batch job XXXXX"
    slurm_job_id = _parse_sbatch_output(stdout)
    log_path = f"{log_dir}/expand-{slurm_job_id}.out"
    logger.info("batch_expand [%s] submitted as Slurm job %s", execution["id"], slurm_job_id)

    update_execution(
        execution["id"],
        status="running",
        slurm_job_id=slurm_job_id,
        log_path=log_path,
    )

    # Start background polling
    _start_job_poller(execution["id"], slurm_job_id)

    execution["slurm_job_id"] = slurm_job_id
    execution["status"] = "running"
    execution["log_path"] = log_path


def _execute_batch_shrink(execution: dict, config, req: OperationRequest):
    """Submit shrink as a Slurm batch job via sbatch."""
    ssh = get_ssh_client()
    project_dir = config.project.project_dir
    log_dir = f"{project_dir}/logs"

    # Submit submit.sh as the sbatch script (not via --wrap) so that
    # submit.sh runs on the host where scontrol/sacct are available.
    # For selected_nodes mode (no job_id), export NODE_LIST so submit.sh
    # can skip sacct resolution.
    export_vars = (
        f"ALL,PROJECT_DIR={project_dir},"
        f"PAYLOAD_DIR={config.project.payload_dir},"
        f"ROCKY_VER={config.project.rocky_ver}"
    )
    if not req.job_id and req.selected_nodes:
        node_list = ",".join(req.selected_nodes)
        export_vars += f",NODE_LIST={node_list}"

    script_args = f"del {req.job_id}" if req.job_id else "del"

    sbatch_cmd = (
        f"mkdir -p {log_dir} && "
        f"sbatch -J shrink "
        f"--partition={req.partition} "
        f"--nodes=1 "
        f"--output={log_dir}/shrink-%j.out "
        f"--error={log_dir}/shrink-%j.err "
        f"--export={export_vars} "
        f"{config.project.submit_script} {script_args}"
    )

    logger.info("batch_shrink [%s] submitting sbatch command: %s", execution["id"], sbatch_cmd)
    exit_code, stdout, stderr = ssh.run(sbatch_cmd)

    if exit_code != 0:
        logger.error("batch_shrink [%s] sbatch failed (exit %d): %s", execution["id"], exit_code, stderr)
        update_execution(execution["id"], status="failed", error=stderr)
        raise RuntimeError(f"sbatch shrink failed: {stderr}")

    slurm_job_id = _parse_sbatch_output(stdout)
    log_path = f"{log_dir}/shrink-{slurm_job_id}.out"
    logger.info("batch_shrink [%s] submitted as Slurm job %s", execution["id"], slurm_job_id)

    update_execution(
        execution["id"],
        status="running",
        slurm_job_id=slurm_job_id,
        log_path=log_path,
    )

    _start_job_poller(execution["id"], slurm_job_id)

    execution["slurm_job_id"] = slurm_job_id
    execution["status"] = "running"
    execution["log_path"] = log_path


def _execute_direct_expand(execution: dict, config, req: OperationRequest):
    """Run expand directly on the headnode via SSH (no Slurm allocation)."""
    if not _direct_mode_lock.acquire(blocking=False):
        update_execution(execution["id"], status="failed", error="Another direct operation is in progress")
        raise RuntimeError(
            "Another direct-mode operation is already running. "
            "Wait for it to complete or use batch mode."
        )

    # Lock is passed into the background thread; it will be released when the
    # thread finishes so it correctly covers the full operation duration.
    _run_direct_operation(
        execution, config, "add",
        occupy_num=req.occupy_num,
        target_nodes=req.selected_nodes,
        lock=_direct_mode_lock,
    )


def _execute_direct_shrink(
    execution: dict, config, req: OperationRequest, target_nodes: list[str]
):
    """Run shrink directly on the headnode via SSH."""
    if not _direct_mode_lock.acquire(blocking=False):
        update_execution(execution["id"], status="failed", error="Another direct operation is in progress")
        raise RuntimeError(
            "Another direct-mode operation is already running. "
            "Wait for it to complete or use batch mode."
        )

    # Lock is passed into the background thread; it will be released when the
    # thread finishes so it correctly covers the full operation duration.
    _run_direct_operation(
        execution, config, "del",
        job_id=req.job_id,
        target_nodes=target_nodes,
        lock=_direct_mode_lock,
    )


def _run_direct_operation(
    execution: dict,
    config,
    action: str,
    occupy_num: int = 0,
    job_id: str | None = None,
    target_nodes: list[str] | None = None,
    lock: threading.Lock | None = None,
):
    """Execute the pre-hook → payload → post-hook pipeline directly via SSH.

    Uses the same Singularity bind mounts, image, and script contract as
    the batch flow, but bypasses Slurm partition allocation.
    """
    ssh = get_ssh_client()
    project_dir = config.project.project_dir
    exec_id = execution["id"]
    log_file = f"{project_dir}/logs/direct-{exec_id}.log"

    update_execution(exec_id, status="running", log_path=log_file)
    execution["status"] = "running"
    execution["log_path"] = log_file

    # Build the direct command that mirrors submit.sh logic.
    # submit.sh already calls `singularity exec` internally for each step, so
    # it must be invoked directly with bash — NOT wrapped inside another
    # `singularity exec` (which would produce a nested/no-op invocation).
    if action == "add":
        # For direct expand, NODE_LIST is set from the inventory-selected nodes.
        node_list = ",".join(target_nodes) if target_nodes else ""
        node_list_export = f"export NODE_LIST={node_list} && " if node_list else ""
        cmd = (
            f"cd {project_dir} && "
            f"export PROJECT_DIR={project_dir} && "
            f"export PAYLOAD_DIR={config.project.payload_dir} && "
            f"export ROCKY_VER={config.project.rocky_ver} && "
            f"{node_list_export}"
            f"mkdir -p $(dirname {log_file}) && "
            f"bash {config.project.submit_script} add "
            f"2>&1 | tee {log_file}"
        )
    else:
        # For direct shrink
        node_list = ",".join(target_nodes) if target_nodes else ""
        job_arg = job_id if job_id else ""
        cmd = (
            f"cd {project_dir} && "
            f"export PROJECT_DIR={project_dir} && "
            f"export PAYLOAD_DIR={config.project.payload_dir} && "
            f"export ROCKY_VER={config.project.rocky_ver} && "
            f"export NODE_LIST={node_list} && "
            f"mkdir -p $(dirname {log_file}) && "
            f"bash {config.project.submit_script} del {job_arg} "
            f"2>&1 | tee {log_file}"
        )

    logger.info("direct_%s [%s] executing command: %s", action, exec_id, cmd)

    def _run_in_background():
        try:
            exit_code, stdout, stderr = ssh.run(cmd, timeout=3600)
            if exit_code == 0:
                logger.info("direct_%s [%s] completed successfully", action, exec_id)
                update_execution(exec_id, status="completed")
            else:
                logger.error("direct_%s [%s] failed (exit %d): %s", action, exec_id, exit_code, stderr or stdout)
                update_execution(exec_id, status="failed", error=stderr or stdout)
        except Exception as e:
            logger.error("direct_%s [%s] exception: %s", action, exec_id, e)
            update_execution(exec_id, status="failed", error=str(e))
        finally:
            # Write a sentinel line so the remote tail -f can self-terminate.
            try:
                ssh.run(f"echo '__LOG_END__' >> {log_file}")
            except Exception:
                pass
            if lock is not None:
                lock.release()

    thread = threading.Thread(target=_run_in_background, daemon=True)
    thread.start()


def _parse_sbatch_output(output: str) -> str:
    """Parse 'Submitted batch job XXXXX' from sbatch output."""
    for line in output.strip().split("\n"):
        if "Submitted batch job" in line:
            parts = line.strip().split()
            return parts[-1]
    raise RuntimeError(f"Could not parse sbatch output: {output}")


def _start_job_poller(execution_id: str, slurm_job_id: str):
    """Start a background thread that polls sacct for job completion."""

    def _poll():
        while True:
            time.sleep(15)
            try:
                state = get_job_state(slurm_job_id)
                job_state = state.get("state", "UNKNOWN")

                if job_state in ("COMPLETED", "FAILED", "CANCELLED", "TIMEOUT", "NODE_FAIL"):
                    status = "completed" if job_state == "COMPLETED" else "failed"
                    update_execution(
                        execution_id,
                        status=status,
                        slurm_state=job_state,
                        end_time=state.get("end_time", ""),
                        elapsed=state.get("elapsed", ""),
                    )
                    break
                else:
                    update_execution(execution_id, slurm_state=job_state)
            except Exception as e:
                logger.warning("Job poller error for %s: %s", slurm_job_id, e)

    thread = threading.Thread(target=_poll, daemon=True)
    thread.start()
