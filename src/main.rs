//! S0 ships a diagnostic handler rather than a route: it reports what actually
//! reached the Lambda through CloudFront, which is the instrument Spike B reads
//! to settle the OAC auth-transport question in §11. S1a replaces it with the
//! axum router.

use lambda_http::http::HeaderMap;
use lambda_http::{Body, Error, Request, Response, run, service_fn};
use serde_json::{Value, json};

/// Header names whose values may be echoed.
///
/// Everything else is reported by name only. `authorization` carries
/// CloudFront's own SigV4 signature and `x-forwarded-authorization` carries the
/// viewer's bearer token, so echoing values wholesale would publish credentials
/// to anyone who can reach the distribution — and the distribution is public.
const ECHOED_HEADERS: &[&str] = &["content-length", "content-type", "x-amz-content-sha256"];

/// Reports which headers arrived, with values only for [`ECHOED_HEADERS`].
///
/// A header that arrived but whose value is withheld reads as `"<present>"`, so
/// "the header never got here" and "the header got here and I am not printing
/// it" stay distinguishable — which is the entire question Spike B is asking.
fn header_report(headers: &HeaderMap) -> Value {
    let mut report = serde_json::Map::new();

    for name in headers.keys() {
        let key = name.as_str().to_ascii_lowercase();

        let value = if ECHOED_HEADERS.contains(&key.as_str()) {
            match headers.get(name).and_then(|v| v.to_str().ok()) {
                Some(v) => Value::String(v.to_string()),
                None => Value::String("<unreadable>".to_string()),
            }
        } else {
            Value::String("<present>".to_string())
        };

        report.insert(key, value);
    }

    Value::Object(report)
}

async fn handler(request: Request) -> Result<Response<Body>, Error> {
    let body = json!({
        "service": "spoilies",
        "stage": "S0",
        "method": request.method().as_str(),
        "path": request.uri().path(),
        "headers": header_report(request.headers()),
    });

    Ok(Response::builder()
        .status(200)
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))?)
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::INFO)
        .with_target(false)
        .without_time()
        .init();

    run(service_fn(handler)).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use lambda_http::http::{HeaderMap, HeaderName, HeaderValue};

    fn headers(pairs: &[(&str, &str)]) -> HeaderMap {
        let mut map = HeaderMap::new();
        for (name, value) in pairs {
            map.insert(
                HeaderName::from_bytes(name.as_bytes()).unwrap(),
                HeaderValue::from_str(value).unwrap(),
            );
        }
        map
    }

    #[test]
    fn echoes_the_body_hash_header() {
        let report = header_report(&headers(&[("x-amz-content-sha256", "abc123")]));
        assert_eq!(report["x-amz-content-sha256"], "abc123");
    }

    #[test]
    fn withholds_the_forwarded_bearer_token() {
        let report = header_report(&headers(&[("x-forwarded-authorization", "Bearer s3cret")]));
        assert_eq!(report["x-forwarded-authorization"], "<present>");
    }

    #[test]
    fn omits_a_header_that_did_not_arrive() {
        let report = header_report(&headers(&[("content-type", "application/json")]));
        assert!(report.get("x-forwarded-authorization").is_none());
    }
}
