"""Execution metadata persistence.

Stores and retrieves execution records as JSON files in the
configured executions directory.
"""

from __future__ import annotations

import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone

logger = logging.getLogger(__name__)


def _executions_dir() -> str:
    from app.config import get_config

    return get_config().storage.executions_dir


def _execution_path(execution_id: str) -> str:
    return os.path.join(_executions_dir(), f"{execution_id}.json")


def create_execution(
    operation: str,
    mode: str,
    partition: str = "",
    target_nodes: list[str] | None = None,
    occupy_num: int = 0,
    job_id: str | None = None,
) -> dict:
    """Create a new execution record and persist it.

    Returns the execution record dict.
    """
    exec_id = str(uuid.uuid4())[:12]
    now = datetime.now(timezone.utc).isoformat()

    record = {
        "id": exec_id,
        "operation": operation,
        "mode": mode,
        "partition": partition,
        "target_nodes": target_nodes or [],
        "occupy_num": occupy_num,
        "job_id": job_id,
        "slurm_job_id": None,
        "slurm_state": None,
        "status": "pending",
        "log_path": None,
        "error": None,
        "created_at": now,
        "updated_at": now,
        "end_time": None,
        "elapsed": None,
    }

    _save(exec_id, record)
    logger.info("Created execution %s: %s %s", exec_id, operation, mode)
    return record


def update_execution(execution_id: str, **kwargs) -> dict | None:
    """Update fields on an existing execution record.

    Returns the updated record or None if not found.
    """
    record = get_execution(execution_id)
    if record is None:
        logger.warning("Execution %s not found for update", execution_id)
        return None

    for key, value in kwargs.items():
        if key in record:
            record[key] = value

    record["updated_at"] = datetime.now(timezone.utc).isoformat()
    _save(execution_id, record)
    return record


def get_execution(execution_id: str) -> dict | None:
    """Load a single execution record by ID."""
    path = _execution_path(execution_id)
    if not os.path.isfile(path):
        return None
    with open(path, "r") as f:
        return json.load(f)


def list_executions(limit: int = 50) -> list[dict]:
    """List execution records, newest first.

    Args:
        limit: Maximum number of records to return.
    """
    executions_dir = _executions_dir()
    if not os.path.isdir(executions_dir):
        return []

    files = sorted(
        (f for f in os.listdir(executions_dir) if f.endswith(".json")),
        key=lambda f: os.path.getmtime(os.path.join(executions_dir, f)),
        reverse=True,
    )

    records = []
    for fname in files[:limit]:
        path = os.path.join(executions_dir, fname)
        try:
            with open(path, "r") as f:
                records.append(json.load(f))
        except (json.JSONDecodeError, OSError) as e:
            logger.warning("Failed to read %s: %s", path, e)

    return records


def _save(execution_id: str, record: dict) -> None:
    """Write execution record to disk."""
    path = _execution_path(execution_id)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(record, f, indent=2)
