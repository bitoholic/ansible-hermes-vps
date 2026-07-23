FROM nousresearch/hermes-agent:latest

USER root

ENV PIP_BREAK_SYSTEM_PACKAGES=1

RUN apt-get update && apt-get install -y \
    ffmpeg \
    libsndfile1 \
    espeak-ng \
    python3-pip \
    default-jdk \
    'android-sdk*' \
    gh \
    git-crypt \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir --ignore-installed "hermes-agent[voice]"

RUN pip install --no-cache-dir --no-deps neutts

USER hermes
