FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir requests aiohttp kubernetes numpy grpcio grpcio-tools

COPY benchmark.py /app/
COPY benchmark_model_armor.py /app/
# The prompts.json will be mounted via configmap or built-in
COPY prompts.json /app/

CMD ["python", "-u", "benchmark.py"]
