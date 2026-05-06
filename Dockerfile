FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        ffmpeg \
        wget \
        ca-certificates \
        bzip2 \
        tar \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY multi-model-audio-transcript-server/requirements.txt /app/requirements.txt
RUN pip3 install --no-cache-dir -r requirements.txt

COPY multi-model-audio-transcript-server/server.py     /app/server.py
COPY multi-model-audio-transcript-server/transcribe.py /app/transcribe.py

RUN mkdir -p /root/.cache/huggingface /root/.cache/local-transcribe/parakeet

EXPOSE 8080

ENTRYPOINT ["python3", "/app/server.py"]
CMD ["--host", "0.0.0.0", "--port", "8080", "--model", "turbo", "--device", "cuda", "--compute-type", "int8"]
