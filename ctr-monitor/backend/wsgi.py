import os

from app import create_app

app = create_app()

if __name__ == "__main__":  # dev: python wsgi.py  (no reloader — it would start a second dispatcher)
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", 5000)), debug=False, use_reloader=False, threaded=True)
