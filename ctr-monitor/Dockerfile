# syntax=docker/dockerfile:1

# ── 1. React UI ─────────────────────────────────────────────────────────────
FROM node:20.18.1-alpine AS ui
WORKDIR /ui
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend/ ./
RUN npm run build

# ── 2. Flask API + analysis worker ──────────────────────────────────────────
FROM python:3.12.8-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MPLBACKEND=Agg \
    MPLCONFIGDIR=/home/ctr/.mpl \
    CTR_DATA_DIR=/data \
    CTR_SCRIPT=/app/ctr_analysis.py \
    CTR_STATIC_DIR=/app/static

COPY backend/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

RUN useradd --system --uid 10001 --create-home ctr && mkdir -p /data && chown ctr:ctr /data
COPY backend/ /app/backend/
COPY ctr_analysis.py /app/ctr_analysis.py
COPY --from=ui /ui/dist /app/static

USER ctr
# warm matplotlib's font cache so the first run doesn't pay for it
RUN python -c "import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot"

WORKDIR /app/backend
EXPOSE 8080
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/api/health', timeout=4)" || exit 1

# one gunicorn worker on purpose: it owns the run dispatcher; heavy work runs in
# per-run subprocesses, threads keep the API responsive meanwhile
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "8", \
     "--timeout", "900", "--graceful-timeout", "30", "--access-logfile", "-", "wsgi:app"]
