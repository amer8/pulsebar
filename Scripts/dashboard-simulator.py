#!/usr/bin/env python3
"""Local DGX Dashboard fixture. Credentials: demo / demo. Never forwards data."""
import argparse
import json
import math
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Dashboard(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/api/login":
            return self.respond(404, {"error": "Not found"})
        try:
            payload = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", 0)), 4096)))
        except (ValueError, TypeError):
            return self.respond(400, {"error": "Invalid JSON"})
        if payload != {"username": "demo", "password": "demo"}:
            return self.respond(401, {"error": "Invalid credentials"})
        self.respond(200, {"token": "simulator-token"})

    def do_GET(self):
        if self.path == "/":
            return self.respond(200, {"dashboard": "PulseBar simulator", "scenario": self.server.scenario})
        if self.headers.get("Authorization") != "Bearer simulator-token" or self.server.scenario == "unauthorized":
            return self.respond(401, {"error": "Session expired"})
        if self.path == "/api/v1/updates/available":
            return self.respond(200, {"available": False})
        if self.path != "/api/v1/gpu_telemetry/stream":
            return self.respond(404, {"error": "Not found"})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        for tick in range(3600):
            try:
                if self.server.scenario == "disconnect" and tick == 3:
                    return
                if self.server.scenario == "heartbeat-only":
                    event = ": heartbeat\n\n"
                else:
                    units = self.server.memory_units
                    factor = 1024 if units == "kib" else 1
                    payload = {"TelemetryForGPUs": [{
                        "percentage_utilization": round(50 + 40 * math.sin(tick / 10), 1),
                        f"memory_total_in_{units}": 131072 * factor,
                        f"memory_available_in_{units}": round((65536 + 24000 * math.cos(tick / 15)) * factor, 1),
                    }]}
                    data = "invalid JSON" if self.server.scenario == "malformed" else json.dumps(payload)
                    event = f"event: gpu_telemetry\ndata: {data}\n\n"
                self.wfile.write(event.encode())
                self.wfile.flush()
                time.sleep(1)
            except (BrokenPipeError, ConnectionResetError):
                return


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=11001)
    parser.add_argument("--memory-units", choices=["kib", "mb"], default="kib", help="Current KiB fields or legacy MB fields")
    parser.add_argument("--scenario", choices=["live", "heartbeat-only", "disconnect", "unauthorized", "malformed"], default="live")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Dashboard)
    server.scenario = args.scenario
    server.memory_units = args.memory_units
    print(f"Simulator: http://127.0.0.1:{server.server_port} ({args.scenario}), demo / demo", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
