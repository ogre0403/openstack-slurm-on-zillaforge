"""Unified node inventory model.

Merges Slurm and OpenStack data into a normalized node inventory with
role classification and mismatch detection.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from enum import Enum

from app.services.slurm_collector import SlurmNode, collect_slurm_nodes
from app.services.openstack_collector import get_all_openstack_hosts

logger = logging.getLogger(__name__)

# Slurm node base states where the node is running jobs or can accept new jobs.
# States like DOWN, DRAIN, FAIL, MAINT, NO_RESPOND, POWER_DOWN, REBOOT, etc.
# are intentionally excluded — they are not considered active.
_SLURM_ACTIVE_BASE_STATES = frozenset({
    "IDLE",
    "ALLOC", "ALLOCATED",
    "MIX", "MIXED",
    "COMP", "COMPLETING",
})


class NodeRole(str, Enum):
    """Inferred role of a node based on Slurm + OpenStack state."""

    SLURM_WORKER = "slurm_worker"
    OPENSTACK_COMPUTE = "openstack_compute"
    TRANSITION = "transition"
    CONFLICT = "conflict"
    UNKNOWN = "unknown"


@dataclass
class NodeRecord:
    """Normalized node record combining Slurm and OpenStack state."""

    node_name: str = ""
    ip: str = ""

    # Slurm state
    slurm_state: str = ""
    slurm_partitions: list[str] = field(default_factory=list)
    slurm_cpus: int = 0
    slurm_alloc_cpus: int = 0
    slurm_present: bool = False

    # OpenStack state
    openstack_compute_registered: bool = False
    openstack_compute_status: str = ""  # enabled / disabled
    openstack_compute_state: str = ""  # up / down
    openstack_network_agents: list[dict] = field(default_factory=list)

    # Derived
    role: NodeRole = NodeRole.UNKNOWN
    notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "node_name": self.node_name,
            "ip": self.ip,
            "slurm_state": self.slurm_state,
            "slurm_partitions": self.slurm_partitions,
            "slurm_cpus": self.slurm_cpus,
            "slurm_alloc_cpus": self.slurm_alloc_cpus,
            "slurm_present": self.slurm_present,
            "openstack_compute_registered": self.openstack_compute_registered,
            "openstack_compute_status": self.openstack_compute_status,
            "openstack_compute_state": self.openstack_compute_state,
            "openstack_network_agents": self.openstack_network_agents,
            "role": self.role.value,
            "notes": self.notes,
        }


def classify_node(record: NodeRecord) -> NodeRecord:
    """Apply role classification rules to a node record.

    Workflow assumptions:
    - slurm→openstack: A Slurm job (ALLOC) installs OpenStack on the node while
      slurmd stays active. Once installation completes, slurmd is shut down
      (node becomes DOWN*) and the OS becomes fully active.
    - openstack→slurm: OS is disabled/removed, then slurmd is started (IDLE).

    Rules:
    - conflict:            both Slurm active AND OpenStack active
    - openstack_compute:   OpenStack active, Slurm inactive/absent
    - slurm_worker:        Slurm active, not registered in OpenStack
    - transition slurm→openstack:
        * Slurm active (any active state) + OS registered but not yet active
          (deploy job is running; a normal job never coexists with a registered OS)
        * Slurm DOWN* + OS registered but not yet active  (slurmd stopped, OS finalizing)
        * Slurm DOWN* + no OS presence                    (slurmd stopped, OS install not started)
    - transition openstack→slurm:
        * OS registered but not active + Slurm IDLE or not present
    - unknown:             node not found in either system
    """
    os_active = (
        record.openstack_compute_registered
        and record.openstack_compute_state == "up"
        and record.openstack_compute_status == "enabled"
    )
    os_registered = record.openstack_compute_registered
    # Extract the base state and any trailing modifier (e.g. "IDLE*" → base "IDLE", modifier "*").
    # The modifier is the single character that remains after stripping the known suffixes.
    _state_upper = record.slurm_state.upper()
    _slurm_base = _state_upper.rstrip("*~#%$@^+")
    _modifier = _state_upper[len(_slurm_base):]  # "" when no modifier

    # Modifiers that indicate the node is unreachable or mid-transition.
    # Even if the base state looks active (e.g. IDLE*), we cannot trust the node.
    #   *  — not responding to slurmd (most common)
    #   ~  — powered off
    #   #  — powering up / being configured
    #   %  — powering down
    #   ^  — rebooting
    # $ (maintenance) and @ (pending reboot) are intentionally NOT listed here:
    # a node under maintenance may still be draining jobs and @ merely schedules
    # a future reboot; in both cases the base-state check below is the real gate.
    _UNHEALTHY_MODIFIERS = frozenset("*~#%^")

    # Human-readable description for each Slurm state modifier.
    _MODIFIER_DESC: dict[str, str] = {
        "*": "not responding to controller",
        "~": "powered off (power saving)",
        "#": "powering up / being configured",
        "%": "powering down",
        "^": "rebooting",
        "$": "in maintenance reservation",
        "@": "pending reboot",
    }

    # True when the base state is healthy but an unhealthy modifier blocks it.
    # This indicates a transient / mid-lifecycle condition rather than a hard failure.
    _modifier_blocked = (
        bool(_modifier)
        and _modifier in _UNHEALTHY_MODIFIERS
        and _slurm_base in _SLURM_ACTIVE_BASE_STATES
    )

    slurm_active = (
        record.slurm_present
        and not _modifier_blocked
        and _slurm_base in _SLURM_ACTIVE_BASE_STATES
    )

    def _slurm_state_note() -> str:
        """Build a human-readable note for the current Slurm state."""
        modifier_part = (
            f" [{_MODIFIER_DESC[_modifier]}]" if _modifier in _MODIFIER_DESC else ""
        )
        return f"Slurm state is {record.slurm_state}{modifier_part}"

    if os_active and slurm_active:
        # Both systems claim the node is active
        record.role = NodeRole.CONFLICT
        record.notes.append(
            "Node is active in both Slurm and OpenStack — possible conflict"
        )
    elif os_active and not slurm_active:
        record.role = NodeRole.OPENSTACK_COMPUTE
        if record.slurm_present:
            record.notes.append(_slurm_state_note() + " (inactive)")
    elif slurm_active and not os_registered:
        record.role = NodeRole.SLURM_WORKER
    elif _modifier_blocked and not os_registered:
        # Base state looks healthy but modifier signals a mid-lifecycle event
        # (e.g. IDLE*, IDLE#). No OpenStack presence yet — node is temporarily
        # unreachable but not transitioning; classify as transition until stable.
        record.role = NodeRole.TRANSITION
        record.notes.append(
            _slurm_state_note() + " — temporarily unreachable, not yet in OpenStack"
        )
    elif os_registered and not os_active:
        # OpenStack is registered but not fully active (disabled / down).
        # Determine direction by the Slurm side:
        #
        #   slurm→openstack (deploy job running, slurmd still up):
        #     Slurm is active (any state) + OS registered but not yet enabled/up.
        #     The active Slurm job IS the deploy job; normal jobs never coexist
        #     with a registered OS compute service.
        #
        #   slurm→openstack (deploy done, slurmd being stopped):
        #     Slurm DOWN* + OS registered but not yet active.
        #
        #   openstack→slurm (OS winding down):
        #     OS registered but not active + Slurm not present or not active.
        record.role = NodeRole.TRANSITION
        if slurm_active:
            record.notes.append(
                f"{_slurm_state_note()} (Slurm active), OpenStack compute registered "
                f"(state={record.openstack_compute_state}, "
                f"status={record.openstack_compute_status})"
                " — transitioning slurm→openstack"
            )
        elif record.slurm_present and _slurm_base == "DOWN" and _modifier == "*":
            record.notes.append(
                f"{_slurm_state_note()} (slurmd stopped), OpenStack compute registered "
                f"(state={record.openstack_compute_state}, "
                f"status={record.openstack_compute_status})"
                " — transitioning slurm→openstack"
            )
        else:
            # Slurm absent or not active, no evidence of a deploy job.
            # → OpenStack is being wound down, Slurm is taking over.
            record.notes.append(
                f"OpenStack compute registered but "
                f"state={record.openstack_compute_state}, "
                f"status={record.openstack_compute_status}"
                " — transitioning openstack→slurm"
            )
    elif record.slurm_present and not slurm_active:
        # NOT os_registered guaranteed here (branch above would have caught it).
        # Slurm present but inactive, no OpenStack presence at all.
        # slurmd was killed and OS registration hasn't started yet.
        record.role = NodeRole.TRANSITION
        if _slurm_base == "DOWN" and _modifier == "*":
            record.notes.append(
                _slurm_state_note()
                + " (slurmd stopped) — transitioning slurm→openstack"
            )
        else:
            record.notes.append(_slurm_state_note() + " — transitioning slurm→openstack")
    else:
        record.role = NodeRole.UNKNOWN
        if not record.slurm_present and not record.openstack_compute_registered:
            record.notes.append("Node not found in Slurm or OpenStack")

    return record


def get_node_inventory() -> list[NodeRecord]:
    """Build the merged node inventory from Slurm and OpenStack.

    Returns a list of NodeRecord with role classification applied.
    """
    # Collect from both sources
    slurm_nodes = collect_slurm_nodes()
    openstack_hosts = get_all_openstack_hosts()

    # Index Slurm nodes by name
    slurm_by_name: dict[str, SlurmNode] = {n.name: n for n in slurm_nodes}

    # Collect all unique node names
    all_names = set(slurm_by_name.keys()) | set(openstack_hosts.keys())

    records = []
    for name in sorted(all_names):
        record = NodeRecord(node_name=name)

        # Populate Slurm fields
        if name in slurm_by_name:
            sn = slurm_by_name[name]
            record.slurm_present = True
            record.slurm_state = sn.state
            record.slurm_partitions = sn.partitions
            record.slurm_cpus = sn.cpus
            record.slurm_alloc_cpus = sn.alloc_cpus

        # Populate OpenStack fields
        if name in openstack_hosts:
            os_info = openstack_hosts[name]
            cs = os_info.get("compute_service", {})
            record.openstack_compute_registered = bool(cs)
            record.openstack_compute_status = cs.get("status", "")
            record.openstack_compute_state = cs.get("state", "")
            record.openstack_network_agents = os_info.get("network_agents", [])

        # Classify
        record = classify_node(record)
        records.append(record)

    logger.info(
        "Built inventory: %d nodes (%d slurm, %d openstack)",
        len(records),
        len(slurm_nodes),
        len(openstack_hosts),
    )
    return records
