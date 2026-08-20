Add a GET /healthz endpoint to this service: 200 with {"ok":true} when the
database ping succeeds within 500ms, 503 with {"ok":false,"reason":...}
otherwise. It must not hold a pool connection on the happy path longer than the
ping needs, and must not be rate-limited like the API routes.
