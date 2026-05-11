"""Verification tests for the orchestration layer.

These tests verify that:
- Batch expand/shrink matches the current sbatch-based behavior
- Direct expand/shrink uses the same hooks, scripts, and environment
- Node-selection shrink resolves or rejects targets correctly
- Completed logs remain accessible
"""

import json
import os
import tempfile
from unittest.mock import MagicMock, patch

import pytest


class TestBatchExpandBehavior:
    """Task 24: Verify batch expand matches current sbatch-based behavior."""

    @patch("app.services.orchestrator.get_ssh_client")
    @patch("app.services.orchestrator.get_config")
    @patch("app.services.orchestrator.create_execution")
    @patch("app.services.orchestrator.update_execution")
    @patch("app.services.orchestrator._start_job_poller")
    def test_batch_expand_submits_sbatch_with_correct_args(
        self, mock_poller, mock_update, mock_create, mock_config, mock_ssh
    ):
        """Batch expand should submit sbatch with partition, nodes, and
        the Singularity-wrapped submit.sh add command."""
        from app.services.orchestrator import execute_expand

        # Setup mocks
        config = MagicMock()
        config.project.project_dir = "/home/cloud-user/resource_manage"
        config.project.payload_dir = "/home/cloud-user/resource_manage/job_scripts"
        config.project.rocky_ver = "9"
        config.project.sif_path = "/home/cloud-user/resource_manage/kolla-ansible-rocky9.sif"
        config.project.submit_script = "/home/cloud-user/resource_manage/job_scripts/submit.sh"
        mock_config.return_value = config

        mock_create.return_value = {"id": "test-001", "status": "pending"}

        ssh = MagicMock()
        ssh.run.return_value = (0, "Submitted batch job 12345\n", "")
        mock_ssh.return_value = ssh

        result = execute_expand(mode="batch", partition="all", occupy_num=2)

        # Verify sbatch was called
        call_args = ssh.run.call_args[0][0]
        assert "sbatch" in call_args
        assert "--partition=all" in call_args
        assert "--nodes=2" in call_args
        assert "submit.sh add" in call_args
        # Orchestrator passes environment into submit.sh, which owns the
        # Singularity bind mounts and image invocation.
        assert "PROJECT_DIR=/home/cloud-user/resource_manage" in call_args
        assert "PAYLOAD_DIR=/home/cloud-user/resource_manage/job_scripts" in call_args
        assert "ROCKY_VER=9" in call_args
        # Verify log path is deterministic
        assert "expand-%j.out" in call_args

    @patch("app.services.orchestrator.get_ssh_client")
    @patch("app.services.orchestrator.get_config")
    @patch("app.services.orchestrator.create_execution")
    @patch("app.services.orchestrator.update_execution")
    @patch("app.services.orchestrator._start_job_poller")
    def test_batch_expand_captures_job_id(
        self, mock_poller, mock_update, mock_create, mock_config, mock_ssh
    ):
        """Batch expand should parse and store the Slurm job ID."""
        from app.services.orchestrator import execute_expand

        config = MagicMock()
        config.project.project_dir = "/home/cloud-user/resource_manage"
        config.project.payload_dir = "/home/cloud-user/resource_manage/job_scripts"
        config.project.rocky_ver = "9"
        config.project.sif_path = "/home/cloud-user/resource_manage/kolla-ansible-rocky9.sif"
        config.project.submit_script = "/home/cloud-user/resource_manage/job_scripts/submit.sh"
        mock_config.return_value = config

        mock_create.return_value = {"id": "test-002", "status": "pending"}
        ssh = MagicMock()
        ssh.run.return_value = (0, "Submitted batch job 67890\n", "")
        mock_ssh.return_value = ssh

        result = execute_expand(mode="batch", partition="odd", occupy_num=1)

        assert result["slurm_job_id"] == "67890"
        assert result["status"] == "running"
        # Verify poller was started
        mock_poller.assert_called_once_with("test-002", "67890")


class TestBatchShrinkBehavior:
    """Task 25: Verify batch shrink matches current sbatch-based behavior."""

    @patch("app.services.orchestrator.get_ssh_client")
    @patch("app.services.orchestrator.get_config")
    @patch("app.services.orchestrator.create_execution")
    @patch("app.services.orchestrator.update_execution")
    @patch("app.services.orchestrator._start_job_poller")
    @patch("app.services.orchestrator.resolve_shrink_targets")
    def test_batch_shrink_by_job_id(
        self, mock_resolve, mock_poller, mock_update, mock_create, mock_config, mock_ssh
    ):
        """Batch shrink by job_id should pass the job ID to submit.sh del."""
        from app.services.orchestrator import execute_shrink

        config = MagicMock()
        config.project.project_dir = "/home/cloud-user/resource_manage"
        config.project.payload_dir = "/home/cloud-user/resource_manage/job_scripts"
        config.project.rocky_ver = "9"
        config.project.sif_path = "/home/cloud-user/resource_manage/kolla-ansible-rocky9.sif"
        config.project.submit_script = "/home/cloud-user/resource_manage/job_scripts/submit.sh"
        mock_config.return_value = config

        mock_resolve.return_value = ["slurm-compute-2", "slurm-compute-3"]
        mock_create.return_value = {"id": "test-003", "status": "pending"}
        ssh = MagicMock()
        ssh.run.return_value = (0, "Submitted batch job 11111\n", "")
        mock_ssh.return_value = ssh

        result = execute_shrink(mode="batch", partition="all", job_id="67890")

        call_args = ssh.run.call_args[0][0]
        assert "sbatch" in call_args
        assert "submit.sh del 67890" in call_args
        assert "shrink-%j.out" in call_args


class TestDirectModeBehavior:
    """Task 26: Verify direct mode uses same hooks/env."""

    @patch("app.services.orchestrator._direct_mode_lock")
    @patch("app.services.orchestrator.get_ssh_client")
    @patch("app.services.orchestrator.get_config")
    @patch("app.services.orchestrator.create_execution")
    @patch("app.services.orchestrator.update_execution")
    def test_direct_expand_uses_same_singularity_binds(
        self, mock_update, mock_create, mock_config, mock_ssh, mock_lock
    ):
        """Direct expand should pass the same submit.sh environment contract."""
        from app.services.orchestrator import _run_direct_operation

        config = MagicMock()
        config.project.project_dir = "/home/cloud-user/resource_manage"
        config.project.payload_dir = "/home/cloud-user/resource_manage/job_scripts"
        config.project.rocky_ver = "9"
        config.project.sif_path = "/home/cloud-user/resource_manage/kolla-ansible-rocky9.sif"
        config.project.submit_script = "/home/cloud-user/resource_manage/job_scripts/submit.sh"

        ssh = MagicMock()
        ssh.run.return_value = (0, "done", "")
        mock_ssh.return_value = ssh

        execution = {"id": "test-direct-1", "status": "pending"}
        _run_direct_operation(execution, config, "add", occupy_num=1)

        # Give the background thread a moment to start
        import time
        time.sleep(0.5)

        call_args = ssh.run.call_args[0][0]
        # The outer command should preserve the same submit.sh entrypoint and
        # exported environment; submit.sh owns the Singularity bind mounts.
        assert "submit.sh add" in call_args
        assert "PROJECT_DIR=" in call_args
        assert "PAYLOAD_DIR=" in call_args
        assert "ROCKY_VER=" in call_args


class TestNodeSelectionShrink:
    """Task 27: Verify node-selection shrink resolves or rejects targets."""

    @patch("app.services.slurm_collector.collect_slurm_nodes")
    @patch("app.services.openstack_collector.get_compute_hosts")
    def test_rejects_unknown_nodes(self, mock_os_hosts, mock_slurm):
        """Should reject nodes not found in Slurm."""
        from app.services.orchestrator import resolve_shrink_targets
        from app.services.slurm_collector import SlurmNode

        mock_slurm.return_value = [
            SlurmNode(name="node-1"),
            SlurmNode(name="node-2"),
        ]

        with pytest.raises(ValueError, match="not found in Slurm"):
            resolve_shrink_targets(None, ["node-1", "node-99"])

    @patch("app.services.slurm_collector.collect_slurm_nodes")
    @patch("app.services.openstack_collector.get_compute_hosts")
    def test_rejects_mixed_origin_nodes(self, mock_os_hosts, mock_slurm):
        """Should reject if some selected nodes are OS computes and some are not."""
        from app.services.orchestrator import resolve_shrink_targets
        from app.services.slurm_collector import SlurmNode

        mock_slurm.return_value = [
            SlurmNode(name="node-1"),
            SlurmNode(name="node-2"),
        ]
        mock_os_hosts.return_value = {"node-1"}  # only node-1 is OS compute

        with pytest.raises(ValueError, match="Mixed selection"):
            resolve_shrink_targets(None, ["node-1", "node-2"])

    @patch("app.services.slurm_collector.collect_slurm_nodes")
    @patch("app.services.openstack_collector.get_compute_hosts")
    def test_rejects_non_openstack_nodes(self, mock_os_hosts, mock_slurm):
        """Should reject if none of the selected nodes are OS computes."""
        from app.services.orchestrator import resolve_shrink_targets
        from app.services.slurm_collector import SlurmNode

        mock_slurm.return_value = [SlurmNode(name="node-1")]
        mock_os_hosts.return_value = set()

        with pytest.raises(ValueError, match="registered as OpenStack computes"):
            resolve_shrink_targets(None, ["node-1"])

    @patch("app.services.slurm_collector.collect_slurm_nodes")
    @patch("app.services.openstack_collector.get_compute_hosts")
    def test_accepts_valid_openstack_nodes(self, mock_os_hosts, mock_slurm):
        """Should accept when all selected nodes are valid OS computes."""
        from app.services.orchestrator import resolve_shrink_targets
        from app.services.slurm_collector import SlurmNode

        mock_slurm.return_value = [
            SlurmNode(name="node-1"),
            SlurmNode(name="node-2"),
        ]
        mock_os_hosts.return_value = {"node-1", "node-2"}

        result = resolve_shrink_targets(None, ["node-1", "node-2"])
        assert set(result) == {"node-1", "node-2"}

    @patch("app.services.orchestrator.get_job_nodes")
    def test_resolves_job_id_to_nodes(self, mock_job_nodes):
        """Should resolve job ID to node list via sacct."""
        from app.services.orchestrator import resolve_shrink_targets

        mock_job_nodes.return_value = ["node-3", "node-4"]
        result = resolve_shrink_targets("12345", [])
        assert result == ["node-3", "node-4"]

    @patch("app.services.orchestrator.get_job_nodes")
    def test_rejects_invalid_job_id(self, mock_job_nodes):
        """Should reject if job ID resolves to no nodes."""
        from app.services.orchestrator import resolve_shrink_targets

        mock_job_nodes.return_value = []
        with pytest.raises(ValueError, match="Could not resolve"):
            resolve_shrink_targets("99999", [])


class TestCompletedLogAccess:
    """Task 28: Verify completed logs remain accessible after execution ends."""

    @patch("app.services.log_manager.get_execution")
    @patch("app.services.log_manager.get_ssh_client")
    def test_completed_batch_logs_accessible(self, mock_ssh, mock_get_exec):
        """Should fetch completed batch logs from headnode via SSH."""
        from app.services.log_manager import get_completed_logs

        mock_get_exec.return_value = {
            "id": "test-log-1",
            "mode": "batch",
            "status": "completed",
            "log_path": "/home/cloud-user/resource_manage/logs/expand-12345.out",
        }

        ssh = MagicMock()
        ssh.run.return_value = (0, "line1\nline2\nline3\n", "")
        mock_ssh.return_value = ssh

        logs = get_completed_logs("test-log-1")
        assert "line1" in logs
        assert "line3" in logs

    @patch("app.services.log_manager.get_execution")
    def test_direct_logs_accessible_locally(self, mock_get_exec):
        """Should read direct mode logs from local filesystem."""
        from app.services.log_manager import get_completed_logs

        with tempfile.NamedTemporaryFile(mode="w", suffix=".log", delete=False) as f:
            f.write("direct log line 1\ndirect log line 2\n")
            log_path = f.name

        try:
            mock_get_exec.return_value = {
                "id": "test-log-2",
                "mode": "direct",
                "status": "completed",
                "log_path": log_path,
            }

            logs = get_completed_logs("test-log-2")
            assert "direct log line 1" in logs
            assert "direct log line 2" in logs
        finally:
            os.unlink(log_path)

    @patch("app.services.log_manager.get_execution")
    def test_missing_execution_raises(self, mock_get_exec):
        """Should raise for non-existent execution."""
        from app.services.log_manager import get_completed_logs

        mock_get_exec.return_value = None
        with pytest.raises(ValueError, match="not found"):
            get_completed_logs("nonexistent")
