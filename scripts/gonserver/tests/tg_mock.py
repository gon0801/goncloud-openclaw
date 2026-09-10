#!/usr/bin/env python3
"""Mock de api.telegram.org para T2/T4. Escucha en 127.0.0.1, registra cada POST
y responde ok:true con message_id incremental (desde --first-id).

Uso: tg_mock.py --log <archivo> [--mode ok|fail-second|fail-third] [--first-id N]
Imprime MOCK_PORT=<puerto> en stdout y sirve hasta SIGTERM/SIGINT.

Cada linea del log es JSON: {"n":..,"path":..,"chat_id":..,"text_len":..,
"has_cr":bool,"caption":..(solo sendPhoto),"photo":bool}.
"""
import argparse
import hashlib
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--mode", default="ok",
                    choices=["ok", "fail-second", "fail-third", "tricky-false",
                             "html-false", "ok-no-mid"])
    ap.add_argument("--first-id", type=int, default=100)
    ap.add_argument("--separators", default="compact", choices=["compact", "spaced"],
                    help="compact imita a Telegram real; spaced prueba tolerancia del parser")
    args = ap.parse_args()
    sep = (",", ":") if args.separators == "compact" else None

    state = {"n": 0, "mid": args.first_id - 1}
    logf = open(args.log, "a", encoding="utf-8")

    class H(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            ctype = self.headers.get("Content-Type", "")
            state["n"] += 1
            rec = {"n": state["n"], "path": self.path, "chat_id": None,
                   "text_len": None, "has_cr": None, "caption": None, "photo": False}
            if "multipart/form-data" in ctype:
                raw = body.decode("utf-8", "replace")
                rec["photo"] = 'name="photo"' in raw
                # extrae campos de texto del multipart de forma simple
                for field in ("chat_id", "caption"):
                    marker = f'name="{field}"'
                    i = raw.find(marker)
                    if i >= 0:
                        j = raw.find("\r\n\r\n", i)
                        k = raw.find("\r\n--", j + 4)
                        if j >= 0 and k >= 0:
                            rec[field] = raw[j + 4:k]
                cap = rec.get("caption") or ""
                rec["text_len"] = len(cap)
                rec["has_cr"] = "\r" in cap
                rec["text_sha"] = hashlib.sha256(cap.encode()).hexdigest()[:16]
            else:
                qs = parse_qs(body.decode("utf-8", "replace"))
                rec["chat_id"] = (qs.get("chat_id") or [None])[0]
                txt = (qs.get("text") or [""])[0]
                rec["text_len"] = len(txt)
                rec["has_cr"] = "\r" in txt
                rec["text_sha"] = hashlib.sha256(txt.encode()).hexdigest()[:16]
            logf.write(json.dumps(rec, ensure_ascii=True) + "\n")
            logf.flush()
            fail = (args.mode == "fail-second" and state["n"] == 2) or \
                   (args.mode == "fail-third" and state["n"] == 3)
            ctype = "application/json"
            if args.mode == "html-false":
                # proxy/WAF HTML con el literal "ok":true adentro: caza parsers grep.
                data = b'<html><body>proxy 502: expected "ok":true marker</body></html>'
                ctype = "text/html"
            else:
                if fail or args.mode == "tricky-false":
                    payload = {"ok": False, "error_code": 400,
                               "description": "waf block id 7"}
                elif args.mode == "ok-no-mid":
                    payload = {"ok": True, "result": {}}
                else:
                    state["mid"] += 1
                    payload = {"ok": True, "result": {"message_id": state["mid"]}}
                data = json.dumps(payload, separators=sep).encode() if sep \
                    else json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a):  # silenciar stderr
            pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    print(f"MOCK_PORT={srv.server_address[1]}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
