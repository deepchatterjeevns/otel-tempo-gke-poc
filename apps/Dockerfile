# Single Dockerfile for both demo images (SERVICE build-arg selects role).
# No OpenTelemetry dependency - the operator injects the SDK at deploy time.
FROM python:3.12-slim
ARG SERVICE=frontend
ENV SERVICE_NAME=${SERVICE}
WORKDIR /app
RUN pip install --no-cache-dir flask==3.0.3 requests==2.32.3
COPY frontend.py backend.py ./
CMD ["sh", "-c", "python ${SERVICE_NAME}.py"]
