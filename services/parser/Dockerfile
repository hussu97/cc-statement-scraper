# syntax=docker/dockerfile:1
# Base image pinned by digest (SRV-13): python:3.12-slim, multi-arch index as of 2026-10-08.
# To update: read the new index digest of python:3.12-slim (e.g.
# `docker buildx imagetools inspect python:3.12-slim`), replace it here and re-run the tests.
FROM python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONPATH=/app \
    PORT=8080

WORKDIR /app

RUN groupadd --system app && useradd --system --gid app --home-dir /app --no-create-home app

# Every dependency is pinned with hashes (`uv pip compile --generate-hashes`), and pip
# refuses anything unpinned or unhashed. The service itself is not pip-installed (that
# would fetch an unpinned build backend): the package is copied and found via PYTHONPATH.
COPY requirements.txt ./
RUN pip install --no-deps --require-hashes --only-binary=:all: -r requirements.txt

COPY ccs_parser ./ccs_parser
RUN chown -R app:app /app

USER app
EXPOSE 8080

# Cloud Run sets $PORT. One worker per container; FastAPI's threadpool handles
# concurrent (blocking) parses. Tune container concurrency in Cloud Run instead.
CMD ["sh", "-c", "exec uvicorn ccs_parser.app:app --host 0.0.0.0 --port ${PORT:-8080} --workers 1 --proxy-headers --forwarded-allow-ips='*' --no-server-header"]
