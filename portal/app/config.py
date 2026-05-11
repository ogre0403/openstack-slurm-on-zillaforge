"""Configuration management for the control plane.

Defines how the app receives OpenStack credentials, SSH access to the
Slurm headnode, and persistent storage paths for execution history and
log metadata.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field


@dataclass
class SSHConfig:
    """SSH connection parameters for the Slurm headnode."""

    host: str = ""
    user: str = "cloud-user"
    key_path: str = "/app/ssh_key"
    port: int = 22
    connect_timeout: int = 10

    @classmethod
    def from_env(cls) -> "SSHConfig":
        return cls(
            host=os.environ.get("SLURM_HEADNODE_HOST", ""),
            user=os.environ.get("SLURM_HEADNODE_USER", "cloud-user"),
            key_path=os.environ.get("SSH_KEY_PATH", "/app/ssh_key"),
            port=int(os.environ.get("SSH_PORT", "22")),
            connect_timeout=int(os.environ.get("SSH_CONNECT_TIMEOUT", "10")),
        )

    def validate(self) -> list[str]:
        """Return a list of validation errors, empty if valid."""
        errors = []
        if not self.host:
            errors.append("SLURM_HEADNODE_HOST is not set")
        if not os.path.isfile(self.key_path):
            errors.append(f"SSH key not found at {self.key_path}")
        return errors


@dataclass
class OpenStackConfig:
    """OpenStack credential and client configuration."""

    cloud: str = "kolla-admin"
    client_config_file: str = "/etc/openstack/clouds.yaml"

    @classmethod
    def from_env(cls) -> "OpenStackConfig":
        return cls(
            cloud=os.environ.get("OS_CLOUD", "kolla-admin"),
            client_config_file=os.environ.get(
                "OS_CLIENT_CONFIG_FILE", "/etc/openstack/clouds.yaml"
            ),
        )

    def validate(self) -> list[str]:
        errors = []
        if not os.path.isfile(self.client_config_file):
            errors.append(
                f"OpenStack client config not found at {self.client_config_file}"
            )
        return errors

    def as_env(self) -> dict[str, str]:
        """Return environment variables needed by openstack CLI."""
        return {
            "OS_CLOUD": self.cloud,
            "OS_CLIENT_CONFIG_FILE": self.client_config_file,
        }


@dataclass
class ProjectConfig:
    """Project layout on the Slurm headnode."""

    project_dir: str = "/home/cloud-user/resource_manage"
    rocky_ver: str = "9"

    @classmethod
    def from_env(cls) -> "ProjectConfig":
        return cls(
            project_dir=os.environ.get(
                "PROJECT_DIR", "/home/cloud-user/resource_manage"
            ),
            rocky_ver=os.environ.get("ROCKY_VER", "9"),
        )

    @property
    def sif_image(self) -> str:
        return f"kolla-ansible-rocky{self.rocky_ver}.sif"

    @property
    def sif_path(self) -> str:
        return f"{self.project_dir}/{self.sif_image}"

    @property
    def payload_dir(self) -> str:
        return f"{self.project_dir}/job_scripts"

    @property
    def submit_script(self) -> str:
        return f"{self.payload_dir}/submit.sh"


@dataclass
class StorageConfig:
    """Persistent storage paths for execution history and logs."""

    data_dir: str = "/data"

    @classmethod
    def from_env(cls) -> "StorageConfig":
        return cls(data_dir=os.environ.get("DATA_DIR", "/data"))

    @property
    def log_dir(self) -> str:
        return os.path.join(self.data_dir, "logs")

    @property
    def executions_dir(self) -> str:
        return os.path.join(self.data_dir, "executions")

    def ensure_dirs(self) -> None:
        """Create storage directories if they don't exist."""
        os.makedirs(self.log_dir, exist_ok=True)
        os.makedirs(self.executions_dir, exist_ok=True)


@dataclass
class AppConfig:
    """Top-level application configuration."""

    ssh: SSHConfig = field(default_factory=SSHConfig)
    openstack: OpenStackConfig = field(default_factory=OpenStackConfig)
    project: ProjectConfig = field(default_factory=ProjectConfig)
    storage: StorageConfig = field(default_factory=StorageConfig)

    @classmethod
    def from_env(cls) -> "AppConfig":
        return cls(
            ssh=SSHConfig.from_env(),
            openstack=OpenStackConfig.from_env(),
            project=ProjectConfig.from_env(),
            storage=StorageConfig.from_env(),
        )

    def validate(self) -> list[str]:
        """Return all validation errors across sub-configs."""
        errors = []
        errors.extend(self.ssh.validate())
        errors.extend(self.openstack.validate())
        return errors


# Singleton loaded once at startup
_config: AppConfig | None = None


def get_config() -> AppConfig:
    """Get or create the application config from environment."""
    global _config
    if _config is None:
        _config = AppConfig.from_env()
        _config.storage.ensure_dirs()
    return _config
