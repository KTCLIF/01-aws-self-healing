#!/usr/bin/env bash
set -euxo pipefail

install -d -m 0755 /opt/resilience-web

token="$(curl --fail --silent --show-error --request PUT \
  --header 'X-aws-ec2-metadata-token-ttl-seconds: 300' \
  http://169.254.169.254/latest/api/token)"
instance_id="$(curl --fail --silent --show-error \
  --header "X-aws-ec2-metadata-token: ${token}" \
  http://169.254.169.254/latest/meta-data/instance-id)"
availability_zone="$(curl --fail --silent --show-error \
  --header "X-aws-ec2-metadata-token: ${token}" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)"

cat >/opt/resilience-web/app.py <<PY
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

IDENTITY = {"instance_id": "${instance_id}", "availability_zone": "${availability_zone}"}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/", "/health"):
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps({"status": "ok", **IDENTITY}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return

HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY

cat >/etc/systemd/system/resilience-web.service <<'UNIT'
[Unit]
Description=Stateless resilience experiment web service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/resilience-web/app.py
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now resilience-web.service
