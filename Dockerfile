FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir mt5linux rpyc

RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe \
    -O /root/mt5setup.exe

# Copy EA files
COPY ["test2.ex5", "/root/test2.ex5"]
COPY ["test3.ex5", "/root/test3.ex5"]
COPY ["test4.ex5", "/root/test4.ex5"]
COPY ["test5.ex5", "/root/test5.ex55"]


RUN cat > /entrypoint.sh <<EOF
#!/bin/bash
set -e

rm -rf /tmp/.X*

Xvfb :1 -screen 0 1280x1024x24 -ac &
sleep 2

fluxbox &

x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &

websockify --web=/usr/share/novnc 8080 0.0.0.0:5900 &

wineboot --init
sleep 5

MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"

if [ ! -f "\$MT5_EXE" ]; then
    wine /root/mt5setup.exe /auto
    sleep 90
fi

wine "\$MT5_EXE" &
sleep 30

DATA_DIR=\$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)

if [ -z "\$DATA_DIR" ]; then
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

mkdir -p "\$DATA_DIR/Experts"

cp "/root/test2.ex5" "\$DATA_DIR/Experts/"
cp "/root/test3.ex5" "\$DATA_DIR/Experts/"
cp "/root/test4.ex5" "\$DATA_DIR/Experts/"
cp "/root/test5.ex5" "\$DATA_DIR/Experts/"



echo "✅ Copied EAs to \$DATA_DIR/Experts/"

ls -la "\$DATA_DIR/Experts/"

python3 -m mt5linux --host 0.0.0.0 --port 8001 &

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
