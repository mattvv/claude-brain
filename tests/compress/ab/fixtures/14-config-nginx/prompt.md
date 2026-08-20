WebSocket connections through /ws/ drop after exactly 60 seconds of idle, and
long API uploads over ~1MB fail with 413. Both work when hitting the app
server directly. What needs to change in this nginx config?
