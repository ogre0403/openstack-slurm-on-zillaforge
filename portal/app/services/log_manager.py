"""Log management for execution log streaming and replay.

Handles:
- Live log streaming for batch mode (via SSH tail on headnode log files)
- Live log streaming for direct mode (via application-managed log files)
- Completed log replay for both modes
"""

from __future__ import annotations

import logging
import os
import time
from typing import Callable, Generator

from app.services.execution_store import get_execution
from app.services.ssh_client import get_ssh_client

logger = logging.getLogger(__name__)


def _should_stop_stream(should_stop: Callable[[], bool] | None) -> bool:
    """Return True when a caller has cancelled the active stream."""
    return bool(should_stop and should_stop())


def get_completed_logs(execution_id: str) -> str:
    """Retrieve the full log content for a completed execution.

    For batch mode: fetches the log from the headnode via SSH.
    For direct mode: reads from the local bastion log file or headnode.
    """
    execution = get_execution(execution_id)
    if execution is None:
        raise ValueError(f"Execution {execution_id} not found")

    log_path = execution.get("log_path")
    if not log_path:
        return ""

    mode = execution.get("mode", "batch")

    if mode == "direct" and os.path.isfile(log_path):
        # Direct mode logs stored locally on bastion
        with open(log_path, "r") as f:
            return f.read()

    # Batch mode or direct mode with remote log path — fetch via SSH
    try:
        ssh = get_ssh_client()
        exit_code, stdout, stderr = ssh.run(f"cat {log_path} 2>/dev/null || echo ''")
        if exit_code == 0:
            return stdout
        logger.warning("Failed to read log %s: %s", log_path, stderr)
        return f"[Log file not available: {log_path}]"
    except Exception as e:
        logger.error("Error fetching log %s: %s", log_path, e)
        return f"[Error reading log: {e}]"


def stream_batch_logs(
    execution_id: str,
    should_stop: Callable[[], bool] | None = None,
) -> Generator[str, None, None]:
    """Stream log lines for a batch-mode execution.

    Uses SSH to tail the Slurm log file on the headnode.
    Yields log lines as they become available.
    """
    execution = get_execution(execution_id)
    if execution is None:
        yield f"[Execution {execution_id} not found]"
        return

    log_path = execution.get("log_path")
    if not log_path:
        yield "[No log path available]"
        return

    ssh = get_ssh_client()

    # Wait briefly for the log file to be created
    for _ in range(10):
        if _should_stop_stream(should_stop):
            return
        exit_code, stdout, _ = ssh.run(f"test -f {log_path} && echo 'exists'")
        if "exists" in stdout:
            break
        time.sleep(2)

    # Tail the log file.  When we know the Slurm job ID we build a
    # self-terminating shell snippet that kills the background `tail -f`
    # once the job leaves squeue, so no orphan processes remain on the
    # headnode.  Without a job ID we fall back to a plain `tail -f`.
    slurm_job_id = execution.get("slurm_job_id")
    if slurm_job_id:
        # Use sacct (not squeue) to detect job termination so that expand
        # jobs are handled correctly.  During expand, slurmd is stopped on
        # the compute nodes; the job therefore never leaves squeue cleanly
        # but sacct will eventually report a terminal state (NODE_FAIL,
        # FAILED, COMPLETED, etc.).  The empty-string branch covers the
        # brief window before sacct has a record for the job.
        tail_cmd = (
            f"tail -f -n +1 {log_path} 2>/dev/null & _TAIL_PID=$!; "
            f"while true; do "
            f"_ST=$(sacct -j {slurm_job_id} -n -o State -X 2>/dev/null | tr -d ' ' | head -1); "
            f"case \"$_ST\" in RUNNING|PENDING|COMPLETING|\"\") sleep 5 ;; *) break ;; esac; "
            f"done; "
            f"sleep 2; "
            f"kill \"$_TAIL_PID\" 2>/dev/null; wait \"$_TAIL_PID\" 2>/dev/null"
        )
    else:
        tail_cmd = f"tail -f -n +1 {log_path} 2>/dev/null"

    try:
        for line in ssh.run_streaming(tail_cmd, timeout=3600):
            if _should_stop_stream(should_stop):
                break
            yield line

            # Check if execution is done
            updated = get_execution(execution_id)
            if updated and updated.get("status") in ("completed", "failed"):
                break
    except Exception as e:
        yield f"[Log streaming error: {e}]"


def stream_direct_logs(
    execution_id: str,
    should_stop: Callable[[], bool] | None = None,
) -> Generator[str, None, None]:
    """Stream log lines for a direct-mode execution.

    For direct mode, logs are written to a file on the headnode
    (via tee in the SSH command). We tail that file via SSH.
    """
    execution = get_execution(execution_id)
    if execution is None:
        yield f"[Execution {execution_id} not found]"
        return

    log_path = execution.get("log_path")
    if not log_path:
        yield "[No log path available]"
        return

    # Direct mode logs are on the headnode (written via tee)
    ssh = get_ssh_client()

    for _ in range(10):
        if _should_stop_stream(should_stop):
            return
        exit_code, stdout, _ = ssh.run(f"test -f {log_path} && echo 'exists'")
        if "exists" in stdout:
            break
        time.sleep(2)

    try:
        # Use awk to wrap tail -f: exit when the sentinel line is seen.
        # This ensures the remote process terminates itself cleanly without
        # relying on the SSH channel close sending a signal.
        tail_cmd = (
            f"tail -f -n +1 {log_path} 2>/dev/null "
            f"| awk '/__LOG_END__/{{exit}} {{print}}'"
        )
        for line in ssh.run_streaming(tail_cmd, timeout=3600):
            if _should_stop_stream(should_stop):
                break
            yield line

            updated = get_execution(execution_id)
            if updated and updated.get("status") in ("completed", "failed"):
                break
    except Exception as e:
        yield f"[Log streaming error: {e}]"


def stream_logs(
    execution_id: str,
    should_stop: Callable[[], bool] | None = None,
) -> Generator[str, None, None]:
    """Stream logs for any execution, dispatching to the correct mode."""
    execution = get_execution(execution_id)
    if execution is None:
        yield f"[Execution {execution_id} not found]"
        return

    mode = execution.get("mode", "batch")
    if mode == "batch":
        yield from stream_batch_logs(execution_id, should_stop=should_stop)
    else:
        yield from stream_direct_logs(execution_id, should_stop=should_stop)
