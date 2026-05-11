"""Cluster Control Plane - Flask application factory."""

import logging
import os

from flask import Flask
from flask_socketio import SocketIO

socketio = SocketIO()


def create_app():
    """Create and configure the Flask application."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )

    app = Flask(
        __name__,
        static_folder="../static",
        template_folder="../templates",
    )

    app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "dev-secret-change-me")
    app.config["DATA_DIR"] = os.environ.get("DATA_DIR", "/data")
    app.config["LOG_DIR"] = os.path.join(app.config["DATA_DIR"], "logs")
    app.config["EXECUTIONS_DIR"] = os.path.join(app.config["DATA_DIR"], "executions")

    # Slurm headnode SSH config
    app.config["SLURM_HEADNODE_HOST"] = os.environ.get("SLURM_HEADNODE_HOST", "")
    app.config["SLURM_HEADNODE_USER"] = os.environ.get("SLURM_HEADNODE_USER", "cloud-user")
    app.config["SSH_KEY_PATH"] = os.environ.get("SSH_KEY_PATH", "/app/ssh_key")

    # OpenStack config
    app.config["OS_CLOUD"] = os.environ.get("OS_CLOUD", "kolla-admin")
    app.config["OS_CLIENT_CONFIG_FILE"] = os.environ.get(
        "OS_CLIENT_CONFIG_FILE", "/etc/openstack/clouds.yaml"
    )

    # Project config
    app.config["PROJECT_DIR"] = os.environ.get(
        "PROJECT_DIR", "/home/cloud-user/resource_manage"
    )
    app.config["ROCKY_VER"] = os.environ.get("ROCKY_VER", "9")

    # Ensure data directories exist
    os.makedirs(app.config["LOG_DIR"], exist_ok=True)
    os.makedirs(app.config["EXECUTIONS_DIR"], exist_ok=True)

    # Register blueprints
    from app.routes.api import api_bp
    from app.routes.views import views_bp

    app.register_blueprint(views_bp)
    app.register_blueprint(api_bp, url_prefix="/api")

    # Initialize SocketIO
    socketio.init_app(app, cors_allowed_origins="*", async_mode="eventlet")

    # Import event handlers so they get registered
    from app import events  # noqa: F401

    # Re-attach job pollers for any executions that were running when the
    # app last stopped. Daemon threads are lost on restart, leaving those
    # records stuck at status="running" forever.
    _resume_orphaned_pollers()

    return app


def _resume_orphaned_pollers():
    """Restart job-state pollers for batch executions orphaned by a restart.

    Also marks any direct-mode executions that were left in 'running' state
    as 'failed', since their background threads cannot survive a restart.
    """
    import logging
    logger = logging.getLogger(__name__)
    try:
        from app.services.execution_store import list_executions, update_execution
        from app.services.orchestrator import _start_job_poller

        for rec in list_executions(limit=200):
            if rec.get("status") != "running":
                continue

            if rec.get("mode") == "batch" and rec.get("slurm_job_id"):
                logger.info(
                    "Resuming poller for orphaned execution %s (Slurm job %s)",
                    rec["id"], rec["slurm_job_id"],
                )
                _start_job_poller(rec["id"], rec["slurm_job_id"])

            elif rec.get("mode") == "direct":
                logger.warning(
                    "Marking orphaned direct execution %s as failed (server restarted)",
                    rec["id"],
                )
                update_execution(
                    rec["id"],
                    status="failed",
                    error="Execution interrupted: server restarted while operation was in progress",
                )
                # Write the sentinel so any orphaned `tail -f | awk` pipeline
                # on the headnode self-terminates instead of running forever.
                log_path = rec.get("log_path")
                if log_path:
                    try:
                        from app.services.ssh_client import get_ssh_client
                        get_ssh_client().run(f"echo '__LOG_END__' >> {log_path}")
                    except Exception as sentinel_err:
                        logger.warning(
                            "Could not write sentinel for orphaned execution %s: %s",
                            rec["id"], sentinel_err,
                        )
    except Exception as e:
        logging.getLogger(__name__).warning("Failed to resume orphaned pollers: %s", e)
