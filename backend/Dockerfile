# Auditioner API image. Build from the REPO ROOT (it needs ../content/catalog):
#     docker build -f backend/Dockerfile -t auditioner-api .
# backend/deploy.sh does this on Cloud Build and deploys to Cloud Run.

FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# OS libraries that opencv-python-headless / onnxruntime / rapidocr need at runtime.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libglib2.0-0 libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv

COPY backend/requirements.txt /srv/requirements.txt
RUN pip install -r /srv/requirements.txt

# Download homr's recognition models into the image so a fresh Cloud Run instance
# never has to fetch them. In homr 0.7.0 `--init` fetches the segmentation and
# transformer models (CPU variants, since the build machine has no GPU — the same
# ones Cloud Run uses) into site-packages and initialises RapidOCR, whose models ship
# inside the rapidocr wheel. At run time the non-root user only reads them.
RUN homr --init

COPY backend/app /srv/app
COPY content/catalog /srv/content/catalog

RUN groupadd --system app \
    && useradd --system --gid app --create-home --home-dir /home/app app \
    && chown -R app:app /srv
USER app

# HOMR_EXTRA_ARGS stays empty: homr 0.7.0 takes only the image path (an unknown flag
# such as --no-title makes it exit 2). OMR_TIMEOUT_SECONDS stays under the app's
# 120 s request timeout (APIClient.swift).
ENV PORT=8080 \
    HOME=/home/app \
    CATALOG_DIR=/srv/content/catalog \
    HOMR_CMD=homr \
    HOMR_EXTRA_ARGS= \
    OMR_TIMEOUT_SECONDS=110 \
    OMR_QUEUE_WAIT_SECONDS=30 \
    DAILY_SCAN_LIMIT=30

EXPOSE 8080

# One worker: the OMR engine already uses every CPU it gets, and the in-memory
# limits in app/limits.py assume a single process per instance.
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port \"${PORT:-8080}\" --workers 1 --proxy-headers --forwarded-allow-ips='*'"]
