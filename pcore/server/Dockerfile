# pshell-core for the Pi (arm64). Build context: ~/pshell-core (deploy.sh puts server/, client/ and web/ there).
# The code is bind-mounted read-only by the compose file, so a deploy of code needs no rebuild;
# the image holds only Python and aiohttp – core sits next to Pi-hole and must stay small.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONDONTWRITEBYTECODE=1

RUN pip install "aiohttp>=3.9,<4"

ENV PYTHONPATH=/app CORE_STATE=/state CORE_WEB=/app/web CORE_PORT=8097 \
    HOST_PROC=/host/proc HOST_SYS=/host/sys CORE_STORAGE=/storage DOCKER_SOCK=/var/run/docker.sock

COPY server/corectl /usr/local/bin/corectl
WORKDIR /app
CMD ["python3", "-m", "pshell_core"]
