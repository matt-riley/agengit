#!/usr/bin/env python3

import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


STORAGE_ROOT = Path(sys.argv[1])
READY_FILE = Path(sys.argv[2])
STORAGE_ROOT.mkdir(parents=True, exist_ok=True)


def resolve_target(path: str):
    stripped = path.lstrip("/")
    if not stripped:
        return None, None
    parts = stripped.split("/", 1)
    bucket = parts[0]
    key = parts[1] if len(parts) > 1 else ""
    return bucket, key


def object_path(bucket: str, key: str) -> Path:
    return STORAGE_ROOT / bucket / key


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        return

    def do_HEAD(self):
        self._handle_object(send_body=False)

    def do_GET(self):
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        if params.get("list-type") == ["2"]:
            self._handle_list(parsed.path, params)
            return
        self._handle_object(send_body=True)

    def do_PUT(self):
        bucket, key = resolve_target(urlparse(self.path).path)
        if bucket is None or not key:
            self.send_error(400)
            return

        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        target = object_path(bucket, key)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(body)

        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _handle_object(self, send_body: bool):
        bucket, key = resolve_target(urlparse(self.path).path)
        if bucket is None or not key:
            self.send_error(404)
            return

        target = object_path(bucket, key)
        if not target.exists():
            self.send_error(404)
            return

        data = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if send_body:
            self.wfile.write(data)

    def _handle_list(self, path: str, params):
        bucket, key = resolve_target(path)
        if bucket is None:
            self.send_error(404)
            return
        if key:
            self.send_error(400)
            return

        prefix = params.get("prefix", [""])[0]
        bucket_root = STORAGE_ROOT / bucket
        keys = []
        if bucket_root.exists():
            for file_path in bucket_root.rglob("*"):
                if not file_path.is_file():
                    continue
                rel = file_path.relative_to(bucket_root).as_posix()
                if rel.startswith(prefix):
                    keys.append(rel)
        keys.sort()

        body = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            "<ListBucketResult>",
            "<IsTruncated>false</IsTruncated>",
        ]
        for key_name in keys:
            body.append("<Contents>")
            body.append(f"<Key>{key_name}</Key>")
            body.append("</Contents>")
        body.append("</ListBucketResult>")
        payload = "".join(body).encode()

        self.send_response(200)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    READY_FILE.write_text(str(server.server_port), encoding="utf-8")
    try:
        server.serve_forever()
    finally:
        READY_FILE.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
