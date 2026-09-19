import os
import requests
from flask import Flask

app = Flask(__name__)
SERVICE = os.environ.get("SERVICE_NAME", "unknown")
BACKEND_URL = os.environ.get("BACKEND_URL", "http://backend:8000")

@app.route("/")
def index():
    # Frontend: call the backend over HTTP. W3C tracecontext headers are
    # propagated automatically by the auto-injected SDK (requests gets
    # instrumented via the injected sitecustomize.py) - this is where the
    # trace becomes "distributed".
    try:
        r = requests.get(BACKEND_URL, timeout=2)
        return f"{SERVICE} -> {r.text}"
    except requests.RequestException as e:
        return f"{SERVICE} backend-error: {e}", 502

if __name__ == "__main__":
    # WARNING: Do not use the development server in production.
    # Run this app using a WSGI server like gunicorn:
    # gunicorn --bind 0.0.0.0:8000 frontend:app
    app.run(host="0.0.0.0", port=8000)
