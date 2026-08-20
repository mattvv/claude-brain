//! Async HTTP helpers over reqwest. The only endpoint we speak to is the local
//! claude-brain proxy on loopback (`http://127.0.0.1:8317`), so no TLS is
//! configured. Nothing here blocks the tokio reactor: the request is issued
//! async and the caller streams the body incrementally.

use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use reqwest::{Client, Response};
use std::str::FromStr;
use std::time::Duration;

/// Join a base URL and a path suffix without doubling or dropping the slash.
pub fn join_url(base: &str, suffix: &str) -> String {
    let base = base.trim_end_matches('/');
    if suffix.is_empty() {
        return base.to_string();
    }
    if suffix.starts_with('/') {
        format!("{base}{suffix}")
    } else {
        format!("{base}/{suffix}")
    }
}

fn build_headers(headers: &[(String, String)]) -> Result<HeaderMap, String> {
    let mut map = HeaderMap::with_capacity(headers.len());
    for (name, value) in headers {
        let header_name = HeaderName::from_str(name)
            .map_err(|error| format!("invalid header name {name}: {error}"))?;
        let header_value = HeaderValue::from_str(value)
            .map_err(|error| format!("invalid header value for {name}: {error}"))?;
        map.insert(header_name, header_value);
    }
    Ok(map)
}

fn client(timeout: Duration) -> Result<Client, String> {
    Client::builder()
        // Applies to the whole request including the streamed body read; a long
        // xhigh consultation can legitimately take minutes, so callers pass a
        // generous value.
        .timeout(timeout)
        .build()
        .map_err(|error| format!("cannot build HTTP client: {error}"))
}

/// POST a JSON body and return the streaming-capable response without buffering
/// it. The caller decides whether to read it all at once (non-streaming) or as
/// an SSE byte stream.
pub async fn post_json(
    url: &str,
    headers: &[(String, String)],
    body: Vec<u8>,
    timeout: Duration,
) -> Result<Response, String> {
    let client = client(timeout)?;
    let header_map = build_headers(headers)?;
    client
        .post(url)
        .headers(header_map)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(body)
        .send()
        .await
        .map_err(|error| format!("request to {url} failed: {error}"))
}

/// GET used only by `brain compress doctor` to probe proxy reachability. Returns
/// the HTTP status on success.
pub async fn get_status(
    url: &str,
    headers: &[(String, String)],
    timeout: Duration,
) -> Result<u16, String> {
    let client = client(timeout)?;
    let header_map = build_headers(headers)?;
    let response = client
        .get(url)
        .headers(header_map)
        .send()
        .await
        .map_err(|error| format!("request to {url} failed: {error}"))?;
    Ok(response.status().as_u16())
}
