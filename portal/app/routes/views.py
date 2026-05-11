"""View routes - serves the single-page UI."""

from flask import Blueprint, render_template

views_bp = Blueprint("views", __name__)


@views_bp.route("/")
def index():
    """Serve the main control plane UI."""
    return render_template("index.html")
