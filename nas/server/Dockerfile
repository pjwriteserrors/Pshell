# pshell-nas for the Pi (arm64). Build context: ~/pshell-nas (deploy.sh puts server/, web/, files/, host.py and
# core-client/ there).
# The code is bind-mounted read-only by the compose file, so a deploy of code needs no rebuild;
# the image holds only the tools, the Python packages and the data files of the tasks.
FROM python:3.12-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg imagemagick ghostscript poppler-utils p7zip-full unrar-free libimage-exiftool-perl \
        clamav clamav-freshclam smartmontools rsync git iputils-ping ca-certificates curl tini \
    && rm -rf /var/lib/apt/lists/*

RUN pip install aiohttp pillow pillow-heif pikepdf opencv-python-headless numpy segno

# face models (OpenCV zoo) and the geonames cities for offline places
RUN mkdir -p /app/models && cd /app/models \
    && curl -fsSL -o face_detection_yunet_2023mar.onnx \
        https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx \
    && curl -fsSL -o face_recognition_sface_2021dec.onnx \
        https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx \
    && curl -fsSL -o cities1000.zip https://download.geonames.org/export/dump/cities1000.zip \
    && python3 -c "import zipfile; zipfile.ZipFile('cities1000.zip').extract('cities1000.txt')" && rm cities1000.zip \
    && curl -fsSL -o countryInfo.txt https://download.geonames.org/export/dump/countryInfo.txt

RUN printf 'DatabaseMirror database.clamav.net\nDatabaseOwner root\nForeground yes\n' > /etc/clamav/pshell-freshclam.conf

ENV PYTHONPATH=/app NAS_STATE=/storage/pshell-nas NAS_FILES=/app/files NAS_MODELS=/app/models NAS_WEB=/app/web \
    CLAMAV_DB=/storage/pshell-nas/clamav NAS_PORT=8096

COPY server/nasctl /usr/local/bin/nasctl
WORKDIR /app
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python3", "-m", "pshell_nas"]
