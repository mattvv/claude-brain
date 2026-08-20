import httpx

class UpstreamFetcher:
    def __init__(self, base_url, timeout=2.0):
        self.base_url = base_url
        self.client = httpx.Client(timeout=timeout)

    def get_profile(self, user_id):
        r = self.client.get(f"{self.base_url}/users/{user_id}/profile")
        r.raise_for_status()
        return r.json()

    def get_entitlements(self, user_id):
        r = self.client.get(f"{self.base_url}/users/{user_id}/entitlements")
        r.raise_for_status()
        return r.json()
