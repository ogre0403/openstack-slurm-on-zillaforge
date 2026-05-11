FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app app
COPY static static
COPY templates templates

RUN mkdir -p /data/logs /data/executions

ENV FLASK_APP=app.main:create_app
ENV FLASK_ENV=production

EXPOSE 5000

CMD ["gunicorn", "--worker-class", "eventlet", "-w", "1", "-b", "0.0.0.0:5000", "app.main:create_app()"]
