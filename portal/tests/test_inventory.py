"""Tests for node inventory classification logic."""

import pytest

from app.services.inventory import (
    NodeRecord,
    NodeRole,
    classify_node,
)


class TestClassifyNode:
    """Test role classification for various Slurm/OpenStack combinations."""

    def test_pure_slurm_worker(self):
        """Node present in Slurm only, idle state → slurm_worker."""
        record = NodeRecord(
            node_name="slurm-compute-1",
            slurm_present=True,
            slurm_state="IDLE",
            slurm_partitions=["all", "odd"],
            slurm_cpus=4,
            openstack_compute_registered=False,
        )
        result = classify_node(record)
        assert result.role == NodeRole.SLURM_WORKER
        assert not result.notes

    def test_slurm_worker_allocated(self):
        """Node present in Slurm, allocated state → slurm_worker."""
        record = NodeRecord(
            node_name="slurm-compute-2",
            slurm_present=True,
            slurm_state="ALLOCATED",
            slurm_cpus=4,
            slurm_alloc_cpus=4,
            openstack_compute_registered=False,
        )
        result = classify_node(record)
        assert result.role == NodeRole.SLURM_WORKER

    def test_active_openstack_compute(self):
        """Node registered as OpenStack compute, not active in Slurm → openstack_compute."""
        record = NodeRecord(
            node_name="slurm-compute-3",
            slurm_present=True,
            slurm_state="DOWN*",
            openstack_compute_registered=True,
            openstack_compute_status="enabled",
            openstack_compute_state="up",
        )
        result = classify_node(record)
        assert result.role == NodeRole.OPENSTACK_COMPUTE

    def test_openstack_compute_no_slurm(self):
        """Node only in OpenStack, not in Slurm → openstack_compute."""
        record = NodeRecord(
            node_name="compute-only-1",
            slurm_present=False,
            openstack_compute_registered=True,
            openstack_compute_status="enabled",
            openstack_compute_state="up",
        )
        result = classify_node(record)
        assert result.role == NodeRole.OPENSTACK_COMPUTE

    def test_conflict_both_active(self):
        """Node active in both Slurm and OpenStack → conflict."""
        record = NodeRecord(
            node_name="slurm-compute-4",
            slurm_present=True,
            slurm_state="IDLE",
            slurm_cpus=4,
            openstack_compute_registered=True,
            openstack_compute_status="enabled",
            openstack_compute_state="up",
        )
        result = classify_node(record)
        assert result.role == NodeRole.CONFLICT
        assert any("conflict" in n.lower() for n in result.notes)

    def test_transition_openstack_disabled(self):
        """OpenStack compute registered but disabled → transition."""
        record = NodeRecord(
            node_name="slurm-compute-5",
            slurm_present=False,
            openstack_compute_registered=True,
            openstack_compute_status="disabled",
            openstack_compute_state="up",
        )
        result = classify_node(record)
        assert result.role == NodeRole.TRANSITION
        assert any("status=disabled" in n for n in result.notes)

    def test_transition_openstack_down(self):
        """OpenStack compute registered but state=down → transition."""
        record = NodeRecord(
            node_name="slurm-compute-6",
            slurm_present=False,
            openstack_compute_registered=True,
            openstack_compute_status="enabled",
            openstack_compute_state="down",
        )
        result = classify_node(record)
        assert result.role == NodeRole.TRANSITION

    def test_transition_slurm_drain(self):
        """Slurm node in DRAIN state, no OpenStack → transition."""
        record = NodeRecord(
            node_name="slurm-compute-7",
            slurm_present=True,
            slurm_state="IDLE+DRAIN",
            openstack_compute_registered=False,
        )
        result = classify_node(record)
        assert result.role == NodeRole.TRANSITION
        assert any("DRAIN" in n for n in result.notes)

    def test_transition_slurm_down(self):
        """Slurm node in DOWN state, no OpenStack → transition."""
        record = NodeRecord(
            node_name="slurm-compute-8",
            slurm_present=True,
            slurm_state="DOWN",
            openstack_compute_registered=False,
        )
        result = classify_node(record)
        assert result.role == NodeRole.TRANSITION

    def test_unknown_neither_system(self):
        """Node not in either system → unknown."""
        record = NodeRecord(
            node_name="orphan-1",
            slurm_present=False,
            openstack_compute_registered=False,
        )
        result = classify_node(record)
        assert result.role == NodeRole.UNKNOWN
        assert any("not found" in n.lower() for n in result.notes)

    def test_openstack_compute_with_slurm_drain(self):
        """OpenStack active + Slurm DRAIN → openstack_compute (Slurm inactive)."""
        record = NodeRecord(
            node_name="slurm-compute-9",
            slurm_present=True,
            slurm_state="DRAIN",
            openstack_compute_registered=True,
            openstack_compute_status="enabled",
            openstack_compute_state="up",
        )
        result = classify_node(record)
        assert result.role == NodeRole.OPENSTACK_COMPUTE
        assert any("inactive" in n.lower() for n in result.notes)
