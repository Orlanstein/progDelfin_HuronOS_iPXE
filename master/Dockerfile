FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        dnsmasq \
        nginx \
        python3 \
    && rm -rf /var/lib/apt/lists/*

COPY dnsmasq.conf /etc/dnsmasq.conf
COPY nginx.conf /etc/nginx/sites-available/default

RUN rm -f /etc/nginx/sites-enabled/default && \
    ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

COPY sync-server.py /usr/local/sbin/sync-server.py
RUN chmod +x /usr/local/sbin/sync-server.py

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
