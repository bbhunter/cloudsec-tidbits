FROM python:3.11-slim

WORKDIR /app

COPY app/requirements.txt .
RUN apt-get update && apt-get install -y openssl && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

EXPOSE 443

CMD ["python", "main.py"]
