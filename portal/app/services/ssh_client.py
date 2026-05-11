"""SSH client wrapper for communicating with the Slurm headnode."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

import paramiko

if TYPE_CHECKING:
    from app.config import SSHConfig

logger = logging.getLogger(__name__)


class SSHClient:
    """Thin wrapper around paramiko for headnode SSH operations."""

    def __init__(self, config: SSHConfig):
        self._config = config

    def _connect(self) -> paramiko.SSHClient:
        """Create a fresh SSH connection.

        Paramiko channels are not safe to multiplex indefinitely across
        long-lived streaming commands and concurrent greenlets. Opening a
        new connection per operation avoids channel-open failures when a
        tailing session overlaps with inventory polling or log replay.
        """
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(
            hostname=self._config.host,
            port=self._config.port,
            username=self._config.user,
            key_filename=self._config.key_path,
            timeout=self._config.connect_timeout,
        )
        return client

    def run(self, command: str, timeout: int = 60) -> tuple[int, str, str]:
        """Execute a command and return (exit_code, stdout, stderr)."""
        client = self._connect()
        logger.debug("SSH exec: %s", command)
        try:
            _, stdout, stderr = client.exec_command(command, timeout=timeout)
            exit_code = stdout.channel.recv_exit_status()
            out = stdout.read().decode("utf-8", errors="replace")
            err = stderr.read().decode("utf-8", errors="replace")
            return exit_code, out, err
        finally:
            client.close()

    def run_streaming(self, command: str, timeout: int = 600):
        """Execute a command and yield stdout lines as they arrive.

        Yields (line: str) for each line of output.
        Returns the exit code after the command completes.
        """
        client = self._connect()
        logger.debug("SSH exec (streaming): %s", command)
        try:
            _, stdout, stderr = client.exec_command(command, timeout=timeout)

            for line in iter(stdout.readline, ""):
                yield line.rstrip("\n")

            exit_code = stdout.channel.recv_exit_status()
            return exit_code
        finally:
            client.close()

    def close(self):
        """Close the SSH connection.

        Connections are short-lived and closed per operation, so this is a
        compatibility no-op for existing callers.
        """
        return None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


# Module-level shared client
_ssh_client: SSHClient | None = None


def get_ssh_client() -> SSHClient:
    """Get or create a shared SSH client instance."""
    global _ssh_client
    if _ssh_client is None:
        from app.config import get_config

        _ssh_client = SSHClient(get_config().ssh)
    return _ssh_client
