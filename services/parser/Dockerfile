# syntax=docker/dockerfile:1
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PORT=8080

WORKDIR /app

RUN groupadd --system app && useradd --system --gid app --home-dir /app --no-create-home app

COPY requirements.txt ./
RUN pip install -r requirements.txt

COPY pyproject.toml ./
COPY ccs_parser ./ccs_parser
RUN pip install --no-deps . && chown -R app:app /app

USER app
EXPOSE 8080

# Cloud Run sets $PORT. One worker per container; FastAPI's threadpool handles
# concurrent (blocking) parses. Tune container concurrency in Cloud Run instead.
CMD ["sh", "-c", "exec uvicorn ccs_parser.app:app --host 0.0.0.0 --port ${PORT:-8080} --workers 1 --proxy-headers --forwarded-allow-ips='*' --no-server-header"]
