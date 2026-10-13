import logging

from flask import Flask, send_from_directory

from . import config


def create_app(start_dispatcher=True):
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    app = Flask(__name__, static_folder=None)
    app.config["MAX_CONTENT_LENGTH"] = config.MAX_UPLOAD_MB * 1024 * 1024
    app.json.ensure_ascii = False

    from .api import bp
    app.register_blueprint(bp)

    # single-page app: real files from the React build, everything else → index.html
    @app.get("/", defaults={"path": ""})
    @app.get("/<path:path>")
    def spa(path):
        if path.startswith("api/"):
            return {"error": "not found"}, 404
        if path and (config.STATIC_DIR / path).is_file():
            return send_from_directory(config.STATIC_DIR, path, max_age=31536000 if path.startswith("assets/") else 0)
        if (config.STATIC_DIR / "index.html").is_file():
            return send_from_directory(config.STATIC_DIR, "index.html", max_age=0)
        return ("frontend not built — run `npm run build` in frontend/ or use the Vite dev server", 404)

    if start_dispatcher:
        from .jobs import dispatcher
        dispatcher.start()
    return app
