# .gitpod.Dockerfile
FROM gitpod/workspace-full

# Flutter + common build deps for web
USER gitpod
RUN sudo apt-get update \
 && sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
 && git clone https://github.com/flutter/flutter.git -b stable /home/gitpod/flutter

ENV PATH="/home/gitpod/flutter/bin:${PATH}"
