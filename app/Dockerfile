# ---------- Build stage ----------
FROM python:3.12-slim AS builder

# Environment variables for Python
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Set working directory
WORKDIR /build

# Install dependencies
COPY requirements.txt .
RUN pip install --upgrade pip --root-user-action=ignore \
    && pip install --root-user-action=ignore --prefix=/install -r requirements.txt

# Copy application code
COPY app.py ./
COPY wsgi.py ./

# ---------- Runtime stage ----------
FROM python:3.12-slim

# Environment variables
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV HOST=0.0.0.0
ENV PORT=5050
ENV DEBUG=false
ENV DB_PATH=/data/app.db

# Create a non-root user (and group) with a fixed UID/GID for the app
RUN addgroup --system appuser && adduser --system --ingroup appuser appuser

# Set working directory
WORKDIR /app

# Copy installed Python packages and app code from the builder stage
COPY --from=builder /install /usr/local
COPY --from=builder /build/app.py ./
COPY --from=builder /build/wsgi.py ./

# Create a directory for the SQLite database and adjust permissions
RUN mkdir -p /data && chown appuser:appuser /data

# Declare volume for persistent storage
VOLUME ["/data"]

# Use non-root user
USER appuser

# Expose application port
EXPOSE 5050

# Healthcheck for monitoring and automation
HEALTHCHECK --interval=3s --timeout=60s --start-period=15s --retries=3 \
    CMD python -c "import sys,socket,urllib.request; socket.setdefaulttimeout(2); sys.exit(0) if urllib.request.urlopen('http://localhost:5050/health').status == 200 else sys.exit(1)"

# Start the application
ENTRYPOINT ["python", "app.py"]

# Alternatively, you can use Gunicorn for production ready deployment
#ENTRYPOINT ["sh", "-c", "gunicorn --bind ${HOST}:${PORT} wsgi:app"]
