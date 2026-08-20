from fetcher import UpstreamFetcher

fetcher = UpstreamFetcher("http://users.internal")

def profile_handler(request):
    user_id = request.path_params["user_id"]
    profile = fetcher.get_profile(user_id)
    ents = fetcher.get_entitlements(user_id)
    return {"profile": profile, "premium": "premium" in ents.get("tiers", [])}

def update_profile(request):
    user_id = request.path_params["user_id"]
    body = request.json()
    # writes go straight upstream; reads may be stale after this returns
    fetcher.client.put(
        f"{fetcher.base_url}/users/{user_id}/profile", json=body
    ).raise_for_status()
    return {"ok": True}
