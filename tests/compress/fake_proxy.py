#!/usr/bin/env python3
"""Offline fake claude-brain proxy for brain-ask contract tests. No network,
no vendor creds, no Claude. Routes by the request model field:
  ok-nonstream : 200 non-streaming with text+thinking blocks and usage
  ok-stream    : 200 SSE with message_start/content_block_delta(text,thinking)/message_delta
  truncated    : 200 (stream or not) with stop_reason=max_tokens
  http-500     : 500 error body
  ab-model     : 200 non-streaming with DETERMINISTIC usage for the A/B harness:
                 input scales with request size; output is 60 for the control arm
                 and 20 when a response-profile instruction is present in system
                 (so a paired run shows an exact, checkable -66.7% output delta)
"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

def sse(events):
    out = []
    for e in events:
        out.append("data: " + json.dumps(e) + "\n\n")
    return "".join(out).encode()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.endswith("/v1/models"):
            self._send(200, json.dumps({"data":[{"id":"fake"}]}).encode(), "application/json")
        else:
            self._send(404, b"{}", "application/json")
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        try:
            req = json.loads(body)
        except Exception:
            self._send(400, b'{"error":"bad json"}', "application/json"); return
        model = req.get("model", "")
        stream = bool(req.get("stream"))
        if model == "ab-model":
            prompt = "".join(
                m.get("content", "") for m in req.get("messages", [])
                if isinstance(m.get("content"), str))
            system = req.get("system", "") or ""
            # The profile instructions all contain one of these phrases; their
            # presence marks the guarded arm (see profile_instruction in ask.rs).
            guarded = any(p in system for p in (
                "concisely", "Report only findings", "root cause",
                "unified diff", "recommendation first"))
            usage = {"input_tokens": 300 + (len(prompt) + len(system)) // 4,
                     "output_tokens": 20 if guarded else 60}
            resp = {"id": "resp_ab_1", "type": "message", "role": "assistant",
                    "model": model, "stop_reason": "end_turn", "stop_sequence": None,
                    "content": [{"type": "text", "text": "AB fixture response."}],
                    "usage": usage}
            self._send(200, json.dumps(resp).encode(), "application/json"); return
        if model == "http-500":
            self._send(500, json.dumps({"type":"error","error":{"message":"boom from fake proxy"}}).encode(), "application/json"); return
        stop = "max_tokens" if model == "truncated" else "end_turn"
        if stream:
            events = [
                {"type":"message_start","message":{"id":"resp_fake_1","type":"message","role":"assistant","model":model,"usage":{"input_tokens":5,"output_tokens":0},"content":[],"stop_reason":None}},
                {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}},
                {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"secret-reasoning-"}},
                {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"do-not-leak"}},
                {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}},
                {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}},
                {"type":"content_block_stop","index":0},
                {"type":"message_delta","delta":{"stop_reason":stop,"stop_sequence":None},"usage":{"input_tokens":305,"output_tokens":2}},
                {"type":"message_stop"},
            ]
            payload = sse(events)
            self.send_response(200)
            self.send_header("Content-Type","text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        else:
            resp = {"id":"resp_fake_2","type":"message","role":"assistant","model":model,
                    "stop_reason":stop,"stop_sequence":None,
                    "content":[{"type":"thinking","thinking":"secret-reasoning-do-not-leak"},
                               {"type":"text","text":"Hello world"}],
                    "usage":{"input_tokens":305,"output_tokens":2}}
            self._send(200, json.dumps(resp).encode(), "application/json")
    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8399
    HTTPServer(("127.0.0.1", port), H).serve_forever()
