"""Slurm state collection over SSH from the headnode.

Uses sinfo, scontrol, squeue, and sacct to gather node and job state.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field

from app.services.ssh_client import get_ssh_client

logger = logging.getLogger(__name__)


@dataclass
class SlurmNode:
    """State of a single Slurm node as reported by scontrol."""

    name: str = ""
    state: str = ""
    cpus: int = 0
    real_memory: int = 0
    partitions: list[str] = field(default_factory=list)
    reason: str = ""
    alloc_cpus: int = 0

    def is_idle(self) -> bool:
        return "IDLE" in self.state.upper()

    def is_allocated(self) -> bool:
        return "ALLOC" in self.state.upper()

    def is_down(self) -> bool:
        return "DOWN" in self.state.upper()

    def is_drain(self) -> bool:
        return "DRAIN" in self.state.upper()


@dataclass
class SlurmJob:
    """Summary of a Slurm job from squeue/sacct."""

    job_id: str = ""
    name: str = ""
    user: str = ""
    state: str = ""
    partition: str = ""
    nodes: str = ""
    node_list: list[str] = field(default_factory=list)
    start_time: str = ""
    end_time: str = ""
    elapsed: str = ""


@dataclass
class SlurmPartition:
    """Summary of a Slurm partition from sinfo."""

    name: str = ""
    state: str = ""
    total_nodes: int = 0
    avail_nodes: int = 0
    nodes: str = ""


def collect_slurm_nodes() -> list[SlurmNode]:
    """Collect node information via scontrol show nodes on the headnode."""
    ssh = get_ssh_client()
    exit_code, stdout, stderr = ssh.run(
        "scontrol show nodes --oneliner 2>/dev/null || echo ''"
    )

    if exit_code != 0:
        logger.warning("scontrol show nodes failed: %s", stderr)
        return []

    nodes = []
    for line in stdout.strip().split("\n"):
        if not line.strip():
            continue
        node = _parse_scontrol_node(line)
        if node.name:
            nodes.append(node)

    logger.info("Collected %d Slurm nodes", len(nodes))
    return nodes


def _parse_scontrol_node(line: str) -> SlurmNode:
    """Parse a single scontrol --oneliner node line into SlurmNode."""
    node = SlurmNode()
    fields = line.split()
    for field_str in fields:
        if "=" not in field_str:
            continue
        key, _, value = field_str.partition("=")
        if key == "NodeName":
            node.name = value
        elif key == "State":
            node.state = value
        elif key == "CPUTot":
            node.cpus = int(value) if value.isdigit() else 0
        elif key == "RealMemory":
            node.real_memory = int(value) if value.isdigit() else 0
        elif key == "Partitions":
            node.partitions = value.split(",") if value else []
        elif key == "Reason":
            node.reason = value
        elif key == "CPUAlloc":
            node.alloc_cpus = int(value) if value.isdigit() else 0
    return node


def collect_slurm_partitions() -> list[SlurmPartition]:
    """Collect partition information via sinfo."""
    ssh = get_ssh_client()
    exit_code, stdout, stderr = ssh.run(
        "sinfo --noheader --format='%P %a %D %A %N' 2>/dev/null || echo ''"
    )

    if exit_code != 0:
        logger.warning("sinfo failed: %s", stderr)
        return []

    partitions = []
    for line in stdout.strip().split("\n"):
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) >= 5:
            name = parts[0].rstrip("*")
            alloc_idle = parts[3].split("/")
            partitions.append(
                SlurmPartition(
                    name=name,
                    state=parts[1],
                    total_nodes=int(parts[2]) if parts[2].isdigit() else 0,
                    avail_nodes=(
                        int(alloc_idle[1]) if len(alloc_idle) > 1 and alloc_idle[1].isdigit() else 0
                    ),
                    nodes=parts[4],
                )
            )

    return partitions


def collect_slurm_jobs(state_filter: str = "") -> list[SlurmJob]:
    """Collect jobs from squeue.

    Args:
        state_filter: Optional Slurm state filter (e.g. "RUNNING", "PENDING").
    """
    ssh = get_ssh_client()
    state_arg = f"--state={state_filter}" if state_filter else ""
    exit_code, stdout, stderr = ssh.run(
        f"squeue {state_arg} --noheader "
        f"--format='%i|%j|%u|%T|%P|%N|%S' 2>/dev/null || echo ''"
    )

    if exit_code != 0:
        logger.warning("squeue failed: %s", stderr)
        return []

    jobs = []
    for line in stdout.strip().split("\n"):
        if not line.strip():
            continue
        parts = line.split("|")
        if len(parts) >= 7:
            jobs.append(
                SlurmJob(
                    job_id=parts[0].strip(),
                    name=parts[1].strip(),
                    user=parts[2].strip(),
                    state=parts[3].strip(),
                    partition=parts[4].strip(),
                    nodes=parts[5].strip(),
                    start_time=parts[6].strip(),
                )
            )

    return jobs


def get_job_nodes(job_id: str) -> list[str]:
    """Resolve a Slurm job ID to its list of node hostnames.

    Uses the same approach as submit.sh: sacct + scontrol show hostnames.
    """
    ssh = get_ssh_client()

    # Get the compact nodelist from sacct
    exit_code, stdout, stderr = ssh.run(
        f"sacct -j {job_id} --noheader --parsable2 "
        f"--format=NodeList | head -1"
    )

    if exit_code != 0 or not stdout.strip():
        logger.warning("sacct for job %s failed: %s", job_id, stderr)
        return []

    compact_nodelist = stdout.strip()
    if not compact_nodelist or compact_nodelist == "None assigned":
        return []

    # Expand compact nodelist to individual hostnames
    exit_code, stdout, stderr = ssh.run(
        f"scontrol show hostnames {compact_nodelist}"
    )

    if exit_code != 0:
        logger.warning("scontrol show hostnames failed: %s", stderr)
        return []

    return [h.strip() for h in stdout.strip().split("\n") if h.strip()]


def get_job_state(job_id: str) -> dict:
    """Get the current state of a Slurm job via sacct."""
    ssh = get_ssh_client()
    exit_code, stdout, stderr = ssh.run(
        f"sacct -j {job_id} --noheader --parsable2 "
        f"--format=JobID,State,ExitCode,Start,End,Elapsed,NodeList "
        f"| head -1"
    )

    if exit_code != 0 or not stdout.strip():
        return {"job_id": job_id, "state": "UNKNOWN"}

    parts = stdout.strip().split("|")
    if len(parts) >= 7:
        return {
            "job_id": parts[0],
            "state": parts[1],
            "exit_code": parts[2],
            "start_time": parts[3],
            "end_time": parts[4],
            "elapsed": parts[5],
            "node_list": parts[6],
        }

    return {"job_id": job_id, "state": "UNKNOWN"}
