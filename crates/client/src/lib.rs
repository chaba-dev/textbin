use reqwest::StatusCode;
use reqwest::blocking::Body;
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::error;
use std::fmt;
use std::io::Read;

const DEFAULT_TEXTBIN_URL: &str = "http://localhost:4400";

#[derive(Debug, Clone)]
pub struct Client {
    base_url: String,
    api_token: Option<String>,
    http: reqwest::blocking::Client,
}

impl Client {
    pub fn from_env() -> Self {
        let base_url =
            std::env::var("TEXTBIN_URL").unwrap_or_else(|_| DEFAULT_TEXTBIN_URL.to_string());
        let api_token = std::env::var("TEXTBIN_TOKEN").ok();

        Self::new(base_url).with_api_token(api_token)
    }

    pub fn new(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into().trim_end_matches('/').to_string(),
            api_token: None,
            http: reqwest::blocking::Client::new(),
        }
    }

    pub fn try_new(base_url: impl Into<String>) -> Result<Self, Error> {
        let base_url = base_url.into().trim_end_matches('/').to_string();
        let parsed = reqwest::Url::parse(&base_url)
            .map_err(|_| Error::InvalidServerUrl(base_url.clone()))?;

        if !matches!(parsed.scheme(), "http" | "https")
            || parsed.host_str().is_none()
            || !parsed.username().is_empty()
            || parsed.password().is_some()
            || parsed.query().is_some()
            || parsed.fragment().is_some()
        {
            return Err(Error::InvalidServerUrl(base_url));
        }

        Ok(Self::new(parsed.to_string()))
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    pub fn with_api_token(mut self, api_token: Option<String>) -> Self {
        self.api_token = api_token.filter(|token| !token.is_empty());
        self
    }

    pub fn create_api_token(
        &self,
        email: &str,
        password: &str,
        name: &str,
    ) -> Result<CreatedApiToken, Error> {
        let url = format!("{}/api/v1/auth/tokens", self.base_url);
        let response = self
            .http
            .post(&url)
            .json(&serde_json::json!({"email": email, "password": password, "name": name}))
            .send()
            .map_err(|source| Error::Request {
                url: url.clone(),
                source,
            })?;

        Ok(decode_response::<CreateApiTokenResponse>(&url, response)?.data)
    }

    pub fn identity(&self) -> Result<Identity, Error> {
        let url = format!("{}/api/v1/me", self.base_url);
        let response = self
            .authorize(self.http.get(&url))
            .send()
            .map_err(|source| Error::Request {
                url: url.clone(),
                source,
            })?;

        Ok(decode_response::<IdentityResponse>(&url, response)?.data)
    }

    pub fn revoke_current_token(&self) -> Result<(), Error> {
        let url = format!("{}/api/v1/me/token", self.base_url);
        let response = self
            .authorize(self.http.delete(&url))
            .send()
            .map_err(|source| Error::Request {
                url: url.clone(),
                source,
            })?;

        ensure_success(&url, response)
    }

    pub fn get_paste(&self, id: &str) -> Result<Paste, Error> {
        let url = self.api_paste_url(id);
        let request = self.http.get(&url);
        let response = self
            .authorize(request)
            .send()
            .map_err(|source| Error::Request {
                url: url.clone(),
                source,
            })?;

        let response = decode_response::<ShowResponse>(&url, response)?;

        Ok(response.data)
    }

    pub fn delete_paste(&self, id: &str) -> Result<(), Error> {
        let url = self.api_paste_url(id);
        let request = self.http.delete(&url);
        let response = self
            .authorize(request)
            .send()
            .map_err(|source| Error::Request {
                url: url.clone(),
                source,
            })?;

        ensure_success(&url, response)
    }

    pub fn paste_url(&self, id: &str) -> String {
        format!("{}/pastes/{id}", self.base_url)
    }

    pub fn raw_paste_url(&self, id: &str) -> String {
        format!("{}/pastes/{id}/raw", self.base_url)
    }

    pub fn create_paste(
        &self,
        data: String,
        syntax_highlight: Option<&str>,
        expires_in: Option<&str>,
        visibility: Option<&str>,
    ) -> Result<CreatedPaste, Error> {
        self.create_paste_body(Body::from(data), syntax_highlight, expires_in, visibility)
    }

    pub fn create_paste_stream<R>(
        &self,
        reader: R,
        syntax_highlight: Option<&str>,
        expires_in: Option<&str>,
        visibility: Option<&str>,
    ) -> Result<CreatedPaste, Error>
    where
        R: Read + Send + 'static,
    {
        self.create_paste_body(Body::new(reader), syntax_highlight, expires_in, visibility)
    }

    fn create_paste_body(
        &self,
        body: Body,
        syntax_highlight: Option<&str>,
        expires_in: Option<&str>,
        visibility: Option<&str>,
    ) -> Result<CreatedPaste, Error> {
        let url = self.create_paste_url(syntax_highlight, expires_in, visibility)?;
        let request = self
            .http
            .post(&url)
            .header(CONTENT_TYPE, "text/plain")
            .body(body);
        let response = self
            .authorize(request)
            .send()
            .map_err(|source| Error::Request {
                url: url.clone(),
                source,
            })?;

        let response = decode_response::<CreateResponse>(&url, response)?;

        Ok(response.data)
    }

    fn create_paste_url(
        &self,
        syntax_highlight: Option<&str>,
        expires_in: Option<&str>,
        visibility: Option<&str>,
    ) -> Result<String, Error> {
        let url = format!("{}/api/v1/pastes", self.base_url);
        let syntax_highlight = syntax_highlight.filter(|syntax| !syntax.is_empty());
        let expires_in = expires_in.filter(|ttl| !ttl.is_empty());
        let visibility = visibility.filter(|visibility| !visibility.is_empty());
        let mut query = Vec::new();

        if let Some(syntax_highlight) = syntax_highlight {
            query.push(("syntax_highlight", syntax_highlight));
        }

        if let Some(expires_in) = expires_in {
            query.push(("expires_in", expires_in));
        }

        if let Some(visibility) = visibility {
            query.push(("visibility", visibility));
        }

        let mut request = self.http.post(&url);

        if !query.is_empty() {
            request = request.query(&query);
        }

        request
            .build()
            .map(|request| request.url().to_string())
            .map_err(|source| Error::Request { url, source })
    }

    fn api_paste_url(&self, id: &str) -> String {
        format!("{}/api/v1/pastes/{id}", self.base_url)
    }

    fn authorize(
        &self,
        request: reqwest::blocking::RequestBuilder,
    ) -> reqwest::blocking::RequestBuilder {
        match &self.api_token {
            Some(api_token) => request.header(AUTHORIZATION, format!("Bearer {api_token}")),
            None => request,
        }
    }
}

#[derive(Debug, Deserialize)]
struct ShowResponse {
    data: Paste,
}

#[derive(Debug, Deserialize)]
struct CreateResponse {
    data: CreatedPaste,
}

#[derive(Debug, Deserialize)]
struct CreateApiTokenResponse {
    data: CreatedApiToken,
}

#[derive(Debug, Deserialize)]
struct IdentityResponse {
    data: Identity,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreatedApiToken {
    pub api_token: String,
    pub user: AuthenticatedUser,
    pub token: ApiTokenMetadata,
}

impl CreatedApiToken {
    pub fn identity(&self) -> Identity {
        Identity {
            user: self.user.clone(),
            token: self.token.clone(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Identity {
    pub user: AuthenticatedUser,
    pub token: ApiTokenMetadata,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AuthenticatedUser {
    pub id: String,
    pub email: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ApiTokenMetadata {
    pub id: String,
    pub name: String,
    pub inserted_at: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Paste {
    pub data: String,
    pub syntax_highlight: String,
    pub visibility: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreatedPaste {
    pub id: String,
    pub syntax_highlight: String,
    pub visibility: String,
    pub expires_at: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ApiErrorResponse {
    errors: ApiErrors,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum ApiErrors {
    Detail { detail: String },
    Fields(BTreeMap<String, Vec<String>>),
}

#[derive(Debug)]
pub enum Error {
    InvalidServerUrl(String),
    Request { url: String, source: reqwest::Error },
    ReadResponse { url: String, source: reqwest::Error },
    Decode { source: serde_json::Error },
    Api { status: StatusCode, message: String },
}

impl Error {
    pub fn unauthorized(&self) -> bool {
        matches!(self, Self::Api { status, .. } if *status == StatusCode::UNAUTHORIZED)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidServerUrl(url) => write!(formatter, "invalid Textbin server URL: {url}"),
            Self::Request { url, .. } => write!(formatter, "failed to request {url}"),
            Self::ReadResponse { url, .. } => {
                write!(formatter, "failed to read response from {url}")
            }
            Self::Decode { .. } => write!(formatter, "failed to decode response"),
            Self::Api { message, .. } => formatter.write_str(message),
        }
    }
}

impl error::Error for Error {
    fn source(&self) -> Option<&(dyn error::Error + 'static)> {
        match self {
            Self::Request { source, .. } | Self::ReadResponse { source, .. } => Some(source),
            Self::Decode { source } => Some(source),
            Self::InvalidServerUrl(_) | Self::Api { .. } => None,
        }
    }
}

fn decode_response<T>(url: &str, response: reqwest::blocking::Response) -> Result<T, Error>
where
    T: for<'de> Deserialize<'de>,
{
    let status = response.status();
    let body = response.text().map_err(|source| Error::ReadResponse {
        url: url.to_string(),
        source,
    })?;

    if !status.is_success() {
        return Err(Error::Api {
            status,
            message: format_api_error(status, &body),
        });
    }

    decode_json(&body)
}

fn ensure_success(url: &str, response: reqwest::blocking::Response) -> Result<(), Error> {
    let status = response.status();
    let body = response.text().map_err(|source| Error::ReadResponse {
        url: url.to_string(),
        source,
    })?;

    if status.is_success() {
        Ok(())
    } else {
        Err(Error::Api {
            status,
            message: format_api_error(status, &body),
        })
    }
}

fn decode_json<T>(body: &str) -> Result<T, Error>
where
    T: for<'de> Deserialize<'de>,
{
    serde_json::from_str(body).map_err(|source| Error::Decode { source })
}

fn format_api_error(status: StatusCode, body: &str) -> String {
    let detail = serde_json::from_str::<ApiErrorResponse>(body)
        .ok()
        .map(format_api_errors)
        .filter(|message| !message.is_empty());

    match detail {
        Some(detail) => detail,
        None => format!("request failed: {status}"),
    }
}

fn format_api_errors(response: ApiErrorResponse) -> String {
    match response.errors {
        ApiErrors::Detail { detail } => detail,
        ApiErrors::Fields(fields) => fields
            .into_iter()
            .flat_map(|(field, messages)| {
                messages
                    .into_iter()
                    .map(move |message| format!("{field} {message}"))
            })
            .collect::<Vec<_>>()
            .join(", "),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    fn read_request_headers(reader: &mut impl Read) -> String {
        let mut request = Vec::new();
        let mut buffer = [0; 1024];

        loop {
            let bytes_read = reader.read(&mut buffer).unwrap();

            if bytes_read == 0 {
                break;
            }

            request.extend_from_slice(&buffer[..bytes_read]);

            if request.windows(4).any(|window| window == b"\r\n\r\n") {
                break;
            }
        }

        String::from_utf8_lossy(&request).into_owned()
    }

    struct ChunkedReader(VecDeque<&'static [u8]>);

    impl Read for ChunkedReader {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            let Some(chunk) = self.0.pop_front() else {
                return Ok(0);
            };

            assert!(chunk.len() <= buffer.len());
            buffer[..chunk.len()].copy_from_slice(chunk);

            Ok(chunk.len())
        }
    }

    #[test]
    fn client_trims_trailing_slash_from_base_url() {
        let client = Client::new("http://localhost:4000/");

        assert_eq!(client.base_url, "http://localhost:4000");
    }

    #[test]
    fn try_new_accepts_http_servers_and_rejects_other_urls() {
        assert_eq!(
            Client::try_new("https://demo.textbin.com/")
                .unwrap()
                .base_url(),
            "https://demo.textbin.com"
        );
        assert!(matches!(
            Client::try_new("file:///tmp/textbin"),
            Err(Error::InvalidServerUrl(_))
        ));
        assert!(matches!(
            Client::try_new("not a URL"),
            Err(Error::InvalidServerUrl(_))
        ));
        assert!(matches!(
            Client::try_new("https://user:password@demo.textbin.com"),
            Err(Error::InvalidServerUrl(_))
        ));
        assert!(matches!(
            Client::try_new("https://demo.textbin.com?redirect=elsewhere"),
            Err(Error::InvalidServerUrl(_))
        ));
    }

    #[test]
    fn decodes_created_api_token_and_identity() {
        let created = decode_json::<CreateApiTokenResponse>(
            r#"{"data":{"api_token":"txb_secret","user":{"id":"user-id","email":"user@example.com"},"token":{"id":"token-id","name":"Laptop","inserted_at":"2026-08-03T00:00:00Z"}}}"#,
        )
        .unwrap()
        .data;

        assert_eq!(created.api_token, "txb_secret");
        assert_eq!(created.user.email, "user@example.com");
        assert_eq!(created.token.name, "Laptop");
    }

    #[test]
    fn builds_canonical_paste_url() {
        let client = Client::new("https://demo.textbin.com/");

        assert_eq!(
            client.paste_url("00000000-0000-0000-0000-000000000000"),
            "https://demo.textbin.com/pastes/00000000-0000-0000-0000-000000000000"
        );
    }

    #[test]
    fn builds_raw_paste_url() {
        let client = Client::new("https://demo.textbin.com/");

        assert_eq!(
            client.raw_paste_url("00000000-0000-0000-0000-000000000000"),
            "https://demo.textbin.com/pastes/00000000-0000-0000-0000-000000000000/raw"
        );
    }

    #[test]
    fn delete_paste_uses_authenticated_api_endpoint() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let request = read_request_headers(&mut stream);

            stream
                .write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
                .unwrap();

            request
        });
        let client = Client::new(format!("http://{address}"))
            .with_api_token(Some("txb_test_token".to_string()));

        client
            .delete_paste("00000000-0000-0000-0000-000000000000")
            .unwrap();

        let request = server.join().unwrap();
        assert!(
            request
                .starts_with("DELETE /api/v1/pastes/00000000-0000-0000-0000-000000000000 HTTP/1.1")
        );
        assert!(
            request
                .to_ascii_lowercase()
                .contains("authorization: bearer txb_test_token")
        );
    }

    #[test]
    fn identity_uses_authenticated_me_endpoint() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let request = read_request_headers(&mut stream);
            let body = r#"{"data":{"user":{"id":"user-id","email":"user@example.com"},"token":{"id":"token-id","name":"CLI","inserted_at":"2026-08-03T00:00:00Z"}}}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
                body.len()
            );

            stream.write_all(response.as_bytes()).unwrap();
            request
        });
        let client = Client::new(format!("http://{address}"))
            .with_api_token(Some("txb_test_token".to_string()));

        let identity = client.identity().unwrap();

        assert_eq!(identity.user.email, "user@example.com");
        let request = server.join().unwrap();
        assert!(request.starts_with("GET /api/v1/me HTTP/1.1"));
        assert!(
            request
                .to_ascii_lowercase()
                .contains("authorization: bearer txb_test_token")
        );
    }

    #[test]
    fn revoke_current_token_uses_authenticated_endpoint() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let request = read_request_headers(&mut stream);

            stream
                .write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
                .unwrap();

            request
        });
        let client = Client::new(format!("http://{address}"))
            .with_api_token(Some("txb_test_token".to_string()));

        client.revoke_current_token().unwrap();

        let request = server.join().unwrap();
        assert!(request.starts_with("DELETE /api/v1/me/token HTTP/1.1"));
        assert!(
            request
                .to_ascii_lowercase()
                .contains("authorization: bearer txb_test_token")
        );
    }

    #[test]
    fn reads_request_headers_delivered_in_multiple_chunks() {
        let mut reader = ChunkedReader(VecDeque::from([
            &b"DELETE /api/v1/pastes/example HTTP/1.1\r\nHost: localhost\r\n"[..],
            &b"Authorization: Bearer txb_test_token\r\n\r\n"[..],
        ]));

        let request = read_request_headers(&mut reader);

        assert!(request.contains("Authorization: Bearer txb_test_token"));
        assert!(request.ends_with("\r\n\r\n"));
    }

    #[test]
    fn with_api_token_ignores_empty_tokens() {
        let client = Client::new("http://localhost:4000/").with_api_token(Some(String::new()));

        assert!(client.api_token.is_none());
    }

    #[test]
    fn create_paste_url_omits_empty_syntax_highlight() {
        let client = Client::new("http://localhost:4000/");

        assert_eq!(
            client.create_paste_url(None, None, None).unwrap(),
            "http://localhost:4000/api/v1/pastes"
        );
        assert_eq!(
            client
                .create_paste_url(Some(""), Some(""), Some(""))
                .unwrap(),
            "http://localhost:4000/api/v1/pastes"
        );
    }

    #[test]
    fn create_paste_url_adds_syntax_highlight_query_param() {
        let client = Client::new("http://localhost:4000/");

        assert_eq!(
            client.create_paste_url(Some("rust"), None, None).unwrap(),
            "http://localhost:4000/api/v1/pastes?syntax_highlight=rust"
        );
    }

    #[test]
    fn create_paste_url_adds_expires_in_query_param() {
        let client = Client::new("http://localhost:4000/");

        assert_eq!(
            client
                .create_paste_url(Some("rust"), Some("1h"), None)
                .unwrap(),
            "http://localhost:4000/api/v1/pastes?syntax_highlight=rust&expires_in=1h"
        );
    }

    #[test]
    fn create_paste_url_adds_visibility_query_param() {
        let client = Client::new("http://localhost:4000/");

        assert_eq!(
            client.create_paste_url(None, None, Some("public")).unwrap(),
            "http://localhost:4000/api/v1/pastes?visibility=public"
        );
    }

    #[test]
    fn create_paste_with_invalid_base_url_returns_request_error() {
        let result =
            Client::new("not a valid URL").create_paste("paste body".to_string(), None, None, None);

        assert!(matches!(result, Err(Error::Request { .. })));
    }

    #[test]
    fn format_api_error_uses_detail_from_json_response() {
        let message = format_api_error(
            StatusCode::BAD_REQUEST,
            r#"{"errors":{"detail":"Paste id must be a valid UUID"}}"#,
        );

        assert_eq!(message, "Paste id must be a valid UUID");
    }

    #[test]
    fn format_api_error_uses_field_errors_from_json_response() {
        let message = format_api_error(
            StatusCode::UNPROCESSABLE_ENTITY,
            r#"{"errors":{"data":["can't be blank"],"syntax_highlight":["can't be blank"]}}"#,
        );

        assert_eq!(
            message,
            "data can't be blank, syntax_highlight can't be blank"
        );
    }

    #[test]
    fn format_api_error_falls_back_to_status_without_json_body() {
        let message = format_api_error(StatusCode::INTERNAL_SERVER_ERROR, "not json");

        assert_eq!(message, "request failed: 500 Internal Server Error");
    }

    #[test]
    fn identifies_only_unauthorized_api_errors_as_unauthorized() {
        let unauthorized = Error::Api {
            status: StatusCode::UNAUTHORIZED,
            message: "Invalid API token".to_string(),
        };
        let server_error = Error::Api {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: "request failed".to_string(),
        };

        assert!(unauthorized.unauthorized());
        assert!(!server_error.unauthorized());
    }

    #[test]
    fn decodes_create_response_metadata() {
        let response = decode_json::<CreateResponse>(
            r#"{"data":{"id":"00000000-0000-0000-0000-000000000000","syntax_highlight":"plain","visibility":"public"}}"#,
        )
        .unwrap();

        assert_eq!(response.data.id, "00000000-0000-0000-0000-000000000000");
        assert_eq!(response.data.syntax_highlight, "plain");
        assert_eq!(response.data.visibility, "public");
        assert_eq!(response.data.expires_at, None);
    }
}
