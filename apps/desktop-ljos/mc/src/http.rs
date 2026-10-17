//! The MC's HTTP side, blocking: called on the driver's blocking pool.

use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use ureq::Agent;
use ureq::tls::{RootCerts, TlsConfig, TlsProvider};
use url::Url;

use crate::core::{HttpAnswer, HttpCall, NetError};
use crate::{CallError, McEvent};

/// How long the descriptor and ticket requests may take.
const ATTEMPT_TIMEOUT: Duration = Duration::from_secs(5);

/// The two agents a connection uses: one with the attempt's timeout, one
/// without for the owner's own requests (a large diff, an upload).
#[derive(Clone)]
pub(crate) struct Http {
    attempt: Agent,
    open: Agent,
}

impl Http {
    pub fn new() -> Self {
        Self {
            attempt: agent(Some(ATTEMPT_TIMEOUT)),
            open: agent(None),
        }
    }

    /// GETs the MC's descriptor.
    pub fn descriptor(&self, url: &Url, token: &str) -> HttpAnswer {
        answer(
            self.attempt
                .get(url.as_str())
                .header("Authorization", bearer(token))
                .call(),
        )
    }

    /// POSTs for a socket ticket.
    pub fn ticket(&self, url: &Url, token: &str) -> HttpAnswer {
        answer(
            self.attempt
                .post(url.as_str())
                .header("Authorization", bearer(token))
                .content_type("application/json")
                .send("{}"),
        )
    }

    /// Runs an owner's request, and says what it came to.
    pub fn run(&self, id: u64, origin: &Url, token: &str, request: HttpCall) -> McEvent {
        match request {
            HttpCall::Post { path, body } => {
                let url = crate::core::at_path(origin, &path);
                let answer = answer(
                    self.open
                        .post(url.as_str())
                        .header("Authorization", bearer(token))
                        .content_type("application/json")
                        .send(body.to_string()),
                );
                McEvent::Reply {
                    id,
                    result: posted(answer),
                }
            }
            HttpCall::Upload {
                relative_url,
                bytes,
                mime_type,
            } => {
                let result = match origin.join(&relative_url) {
                    Ok(url) => uploaded(answer(
                        self.open
                            .post(url.as_str())
                            .content_type(if mime_type.is_empty() {
                                "application/octet-stream"
                            } else {
                                &mime_type
                            })
                            .send(&bytes[..]),
                    )),
                    Err(error) => Err(CallError::new(error.to_string())),
                };
                McEvent::Reply { id, result }
            }
            HttpCall::Download { relative_url } => {
                // The URL carries its own query (the signature).
                let result = match origin.join(&relative_url) {
                    Ok(url) => downloaded(answer(self.open.get(url.as_str()).call())),
                    Err(error) => Err(CallError::new(error.to_string())),
                };
                McEvent::Bytes { id, result }
            }
        }
    }
}

/// The client's TLS: the system's trust store, as the Qt client has it.
pub(crate) fn tls() -> Arc<rustls::ClientConfig> {
    use rustls_platform_verifier::BuilderVerifierExt;
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .expect("ring supports the default protocol versions")
    .with_platform_verifier()
    .expect("the platform verifier is available")
    .with_no_client_auth();
    Arc::new(config)
}

pub(crate) fn agent(timeout: Option<Duration>) -> Agent {
    Agent::config_builder()
        .timeout_global(timeout)
        .http_status_as_error(false)
        .tls_config(
            TlsConfig::builder()
                .provider(TlsProvider::Rustls)
                .root_certs(RootCerts::PlatformVerifier)
                .build(),
        )
        .build()
        .into()
}

/// GETs `url` for what it serves, at most `limit` bytes of it (one more
/// than that tells the caller it is larger). Blocking: for a thread of the
/// caller's own. An error is worded for the user.
pub fn fetch(url: &str, timeout: Duration, limit: usize) -> Result<Vec<u8>, String> {
    use std::io::Read;
    let mut response = agent(Some(timeout))
        .get(url)
        .call()
        .map_err(|error| error.to_string())?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("The server answered {status}."));
    }
    let mut body = Vec::new();
    response
        .body_mut()
        .with_config()
        .limit(u64::MAX)
        .reader()
        .take(limit as u64 + 1)
        .read_to_end(&mut body)
        .map_err(|error| error.to_string())?;
    Ok(body)
}

fn bearer(token: &str) -> String {
    format!("Bearer {token}")
}

fn answer(response: Result<ureq::http::Response<ureq::Body>, ureq::Error>) -> HttpAnswer {
    match response {
        Ok(mut response) => {
            let status = response.status().as_u16();
            match response
                .body_mut()
                .with_config()
                .limit(u64::MAX)
                .read_to_vec()
            {
                Ok(body) => HttpAnswer {
                    status: Some(status),
                    body,
                    error: None,
                },
                Err(error) => HttpAnswer {
                    status: Some(status),
                    body: Vec::new(),
                    error: Some(net_error(error)),
                },
            }
        }
        Err(error) => HttpAnswer {
            status: None,
            body: Vec::new(),
            error: Some(net_error(error)),
        },
    }
}

fn net_error(error: ureq::Error) -> NetError {
    use std::io::ErrorKind;
    match error {
        ureq::Error::Timeout(_) => NetError::Timeout,
        ureq::Error::HostNotFound => NetError::Unreachable("Host not found".to_owned()),
        ureq::Error::Io(io) if io.kind() == ErrorKind::TimedOut => NetError::Timeout,
        ureq::Error::Io(io) if io.kind() == ErrorKind::ConnectionRefused => {
            NetError::Unreachable("Connection refused".to_owned())
        }
        ureq::Error::ConnectionFailed => NetError::Unreachable("Connection failed".to_owned()),
        other => NetError::Other(other.to_string()),
    }
}

fn status_error(answer: &HttpAnswer) -> String {
    match (answer.status, &answer.error) {
        (Some(status), _) => format!("HTTP {status}"),
        (None, Some(NetError::Timeout)) => "timeout".to_owned(),
        (None, Some(NetError::Unreachable(message) | NetError::Other(message))) => message.clone(),
        (None, None) => "no answer".to_owned(),
    }
}

fn success(answer: &HttpAnswer) -> bool {
    answer.error.is_none() && answer.status.is_some_and(|s| (200..300).contains(&s))
}

// A refusal's error is the body's `message`, `detail` or `_tag`, else the HTTP
// status; its detail is then the body.
fn posted(answer: HttpAnswer) -> Result<Value, CallError> {
    let body = match serde_json::from_slice::<Value>(&answer.body) {
        Ok(body @ Value::Object(_)) => body,
        _ => Value::Null,
    };
    if success(&answer) {
        return Ok(body);
    }
    let message = ["message", "detail", "_tag"]
        .into_iter()
        .filter_map(|key| body.get(key)?.as_str())
        .find(|text| !text.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| status_error(&answer));
    Err(CallError {
        message,
        detail: body,
    })
}

// The MC answers a refused upload in plain words.
fn uploaded(answer: HttpAnswer) -> Result<Value, CallError> {
    if success(&answer) {
        return Ok(Value::Null);
    }
    let message = match serde_json::from_slice::<Value>(&answer.body) {
        Ok(Value::Object(body)) => body
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        _ => String::from_utf8_lossy(&answer.body).trim().to_owned(),
    };
    Err(CallError::new(if message.is_empty() {
        status_error(&answer)
    } else {
        message
    }))
}

fn downloaded(answer: HttpAnswer) -> Result<Vec<u8>, CallError> {
    if success(&answer) {
        Ok(answer.body)
    } else {
        Err(CallError::new(status_error(&answer)))
    }
}
