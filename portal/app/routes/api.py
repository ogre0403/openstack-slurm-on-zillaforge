"""API routes for the control plane."""

import logging

from flask import Blueprint, current_app, jsonify, request

logger = logging.getLogger(__name__)

api_bp = Blueprint("api", __name__)


@api_bp.route("/health")
def health():
    """Health check endpoint."""
    return jsonify({"status": "ok"})


@api_bp.route("/inventory")
def get_inventory():
    """Get the merged node inventory."""
    from app.services.inventory import get_node_inventory

    try:
        nodes = get_node_inventory()
        return jsonify({"nodes": [n.to_dict() for n in nodes]})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@api_bp.route("/operations/expand", methods=["POST"])
def expand():
    """Trigger an expand operation."""
    from app.services.orchestrator import execute_expand

    data = request.get_json() or {}
    mode = data.get("mode", "batch")
    partition = data.get("partition", "all")
    occupy_num = data.get("occupy_num", 1)
    selected_nodes = data.get("selected_nodes", [])

    logger.info(
        "API expand triggered: mode=%s partition=%s occupy_num=%d selected_nodes=%s",
        mode, partition, occupy_num, selected_nodes,
    )

    try:
        result = execute_expand(
            mode=mode,
            partition=partition,
            occupy_num=occupy_num,
            selected_nodes=selected_nodes,
        )
        logger.info("API expand accepted: execution_id=%s", result.get("id"))
        return jsonify(result)
    except Exception as e:
        logger.error("API expand failed: %s", e)
        return jsonify({"error": str(e)}), 500


@api_bp.route("/operations/shrink", methods=["POST"])
def shrink():
    """Trigger a shrink operation."""
    from app.services.orchestrator import execute_shrink

    data = request.get_json() or {}
    mode = data.get("mode", "batch")
    partition = data.get("partition", "all")
    job_id = data.get("job_id")
    selected_nodes = data.get("selected_nodes", [])

    logger.info(
        "API shrink triggered: mode=%s partition=%s job_id=%s selected_nodes=%s",
        mode, partition, job_id, selected_nodes,
    )

    try:
        result = execute_shrink(
            mode=mode,
            partition=partition,
            job_id=job_id,
            selected_nodes=selected_nodes,
        )
        logger.info("API shrink accepted: execution_id=%s", result.get("id"))
        return jsonify(result)
    except Exception as e:
        logger.error("API shrink failed: %s", e)
        return jsonify({"error": str(e)}), 500


@api_bp.route("/executions")
def list_executions():
    """List execution history."""
    from app.services.execution_store import list_executions as _list

    try:
        executions = _list()
        return jsonify({"executions": executions})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@api_bp.route("/executions/<execution_id>")
def get_execution(execution_id):
    """Get a single execution record."""
    from app.services.execution_store import get_execution as _get

    try:
        execution = _get(execution_id)
        if execution is None:
            return jsonify({"error": "not found"}), 404
        return jsonify(execution)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@api_bp.route("/executions/<execution_id>/logs")
def get_execution_logs(execution_id):
    """Get logs for a completed execution."""
    from app.services.log_manager import get_completed_logs

    try:
        logs = get_completed_logs(execution_id)
        return jsonify({"logs": logs})
    except Exception as e:
        return jsonify({"error": str(e)}), 500
