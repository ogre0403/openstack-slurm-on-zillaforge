"""SocketIO event handlers for real-time log streaming."""

from __future__ import annotations

import logging

from flask import request
from flask_socketio import emit

from app.main import socketio
from app.services.log_manager import stream_logs

logger = logging.getLogger(__name__)

_active_log_streams: dict[str, str] = {}


def _cancel_log_stream(session_id: str, execution_id: str | None = None) -> None:
    """Mark the current log stream for a session as cancelled."""
    active_execution_id = _active_log_streams.get(session_id)
    if active_execution_id is None:
        return

    if execution_id is not None and active_execution_id != execution_id:
        return

    _active_log_streams.pop(session_id, None)


@socketio.on("subscribe_logs")
def handle_subscribe_logs(data):
    """Client subscribes to live log streaming for an execution.

    Expected data: {"execution_id": "..."}
    """
    execution_id = data.get("execution_id")
    if not execution_id:
        emit("log_error", {"error": "execution_id required"})
        return

    session_id = request.sid
    _cancel_log_stream(session_id)
    _active_log_streams[session_id] = execution_id

    logger.info("Client subscribed to logs for %s", execution_id)
    emit("log_started", {"execution_id": execution_id})

    try:
        for line in stream_logs(
            execution_id,
            should_stop=lambda: _active_log_streams.get(session_id) != execution_id,
        ):
            emit("log_line", {"execution_id": execution_id, "line": line})
    except Exception as e:
        logger.error("Log streaming error for %s: %s", execution_id, e)
        emit("log_error", {"execution_id": execution_id, "error": str(e)})
    finally:
        _cancel_log_stream(session_id, execution_id)

    emit("log_ended", {"execution_id": execution_id})


@socketio.on("unsubscribe_logs")
def handle_unsubscribe_logs(data):
    """Client stops live log streaming for the current execution."""
    execution_id = (data or {}).get("execution_id")
    _cancel_log_stream(request.sid, execution_id)


@socketio.on("connect")
def handle_connect():
    logger.info("Client connected")
    emit("connected", {"status": "ok"})


@socketio.on("disconnect")
def handle_disconnect():
    _cancel_log_stream(request.sid)
    logger.info("Client disconnected")
