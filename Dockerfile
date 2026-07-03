FROM ghcr.io/open-webui/open-webui:cuda

USER root

# Update package list and install system dependencies
RUN apt-get update && apt-get install -y \
    tesseract-ocr \
    tesseract-ocr-eng \
    poppler-utils \
    libmagic1 \
    # Add ffmpeg (CRITICAL for audio transcription)
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# 2. Pre-create the Whisper cache folder and give permissions to user 1000
RUN mkdir -p /app/backend/data/cache/whisper \
    && chown -R 1000:1000 /app/backend/data/cache/whisper

# Install enhanced PDF processing Python packages
RUN pip install --no-cache-dir \
    unstructured[pdf]==0.11.6 \
    pdfplumber==0.10.3 \
    pytesseract==0.3.10 \
    python-magic==0.4.27 \
    pymupdf==1.23.8 \
    pdf2image==1.16.3 \
    # Ensure Whisper and its dependencies are present
    openai-whisper faster-whisper

# Switch back to non-root user
USER 1000
