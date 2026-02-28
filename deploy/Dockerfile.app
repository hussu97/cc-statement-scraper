# Dockerfile.app — combined image with Playwright for the scraping worker.
# Also used for Render free-tier where the worker runs embedded in the API process
# (CCS_PLATFORM_EMBEDDED_WORKER=true), since the API process must be able to
# launch a browser in that deployment model.
#
# For a docker-compose deployment where the API and worker are separate containers,
# use Dockerfile.api for the api service (no Playwright, ~500 MB smaller).

FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONPATH=/app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY backend/requirements.txt backend/requirements-dev.txt backend/pyproject.toml README.md ./
COPY backend/alembic.ini ./
COPY backend/alembic ./alembic
COPY backend/config ./config
COPY backend/ccs_platform ./ccs_platform

RUN pip install --upgrade pip \
    && pip install -r requirements.txt

# Browser runtime required by scraping workers.
RUN python -m playwright install --with-deps chromium

EXPOSE 8040

CMD ["python", "-m", "ccs_platform.cli", "api", "--host", "0.0.0.0", "--port", "8040"]
