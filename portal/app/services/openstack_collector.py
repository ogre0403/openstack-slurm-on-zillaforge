"""OpenStack state collection on the bastion.

Uses the openstack CLI with existing credential files to query
compute services and network agents.
"""

from __future__ import annotations

import json
import logging
import subprocess
from dataclasses import dataclass, field

from app.config import get_config

logger = logging.getLogger(__name__)


@dataclass
class OpenStackComputeService:
    """A nova-compute service entry."""

    host: str = ""
    binary: str = ""
    status: str = ""  # enabled / disabled
    state: str = ""  # up / down
    zone: str = ""
    id: str = ""


@dataclass
class OpenStackNetworkAgent:
    """A neutron network agent entry."""

    host: str = ""
    agent_type: str = ""
    alive: bool = False
    admin_state_up: bool = False
    binary: str = ""
    id: str = ""


def _run_openstack_cli(args: list[str]) -> str:
    """Run an openstack CLI command with project credentials.

    Returns stdout on success, raises on failure.
    """
    config = get_config()
    env = {
        **dict(__import__("os").environ),
        **config.openstack.as_env(),
    }

    cmd = ["openstack"] + args + ["-f", "json"]
    logger.debug("Running: %s", " ".join(cmd))

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=60,
        env=env,
    )

    if result.returncode != 0:
        logger.warning("openstack CLI failed: %s", result.stderr)
        raise RuntimeError(f"openstack CLI error: {result.stderr}")

    return result.stdout


def collect_compute_services() -> list[OpenStackComputeService]:
    """Query OpenStack for all nova-compute services."""
    try:
        raw = _run_openstack_cli(["compute", "service", "list"])
        data = json.loads(raw)
    except Exception as e:
        logger.error("Failed to collect compute services: %s", e)
        return []

    services = []
    for entry in data:
        svc = OpenStackComputeService(
            host=entry.get("Host", ""),
            binary=entry.get("Binary", ""),
            status=entry.get("Status", ""),
            state=entry.get("State", ""),
            zone=entry.get("Zone", ""),
            id=str(entry.get("ID", "")),
        )
        if svc.binary == "nova-compute":
            services.append(svc)

    logger.info("Collected %d compute services", len(services))
    return services


def collect_network_agents() -> list[OpenStackNetworkAgent]:
    """Query OpenStack for all network agents."""
    try:
        raw = _run_openstack_cli(["network", "agent", "list"])
        data = json.loads(raw)
    except Exception as e:
        logger.error("Failed to collect network agents: %s", e)
        return []

    agents = []
    for entry in data:
        agents.append(
            OpenStackNetworkAgent(
                host=entry.get("Host", ""),
                agent_type=entry.get("Agent Type", ""),
                alive=entry.get("Alive", False),
                admin_state_up=entry.get("State", False),
                binary=entry.get("Binary", ""),
                id=str(entry.get("ID", "")),
            )
        )

    logger.info("Collected %d network agents", len(agents))
    return agents


def get_compute_hosts() -> set[str]:
    """Return the set of hostnames that are registered as nova-compute."""
    services = collect_compute_services()
    return {s.host for s in services if s.state == "up" and s.status == "enabled"}


def get_all_openstack_hosts() -> dict[str, dict]:
    """Return a dict of hostname -> OpenStack registration info.

    Includes compute service state and network agent presence.
    """
    services = collect_compute_services()
    agents = collect_network_agents()

    hosts: dict[str, dict] = {}

    for svc in services:
        hosts.setdefault(svc.host, {})
        hosts[svc.host]["compute_service"] = {
            "status": svc.status,
            "state": svc.state,
            "zone": svc.zone,
        }

    for agent in agents:
        if agent.host not in hosts:
            continue
        hosts[agent.host].setdefault("network_agents", [])
        hosts[agent.host]["network_agents"].append(
            {
                "agent_type": agent.agent_type,
                "alive": agent.alive,
                "binary": agent.binary,
            }
        )

    return hosts
