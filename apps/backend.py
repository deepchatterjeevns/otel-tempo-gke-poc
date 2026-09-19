import os
import random
import time
from flask import Flask

app = Flask(__name__)
SERVICE = os.environ.get("SERVICE_NAME", "unknown")

@app.route("/")
def index():
    # The artificial latency the trace waterfall will reveal: 0-50ms random
    # sleep attributed to the backend span - the "smoking gun" the POC's
    # evidence script extracts from Tempo.
    time.sleep(random.uniform(0, 0.05))
    return f"{SERVICE} ok\n"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
