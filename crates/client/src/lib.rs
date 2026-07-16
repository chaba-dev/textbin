use reqwest::StatusCode;
use reqwest::blocking::Body;
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::error;
use std::fmt;
use std::io::Read;

const DEFAULT_TEXTBIN_URL: &str = "http://localhost:4000";

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

    pub fn with_api_token(mut self, api_token: Option<String>) -> Self {
        self.api_token = api_token.filter(|token| !token.is_empty());
        self
    }

    pub fn get_paste(&self, id: &str) -> Result<Paste, Error> {
        let url = format!("{}/api/v1/pastes/{id}", self.base_url);
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

    pub fn create_paste(
        &self,
        data: String,
        syntax_highlight: Option<&str>,
    ) -> Result<CreatedPaste, Error> {
        self.create_paste_body(Body::from(data), syntax_highlight)
    }

    pub fn create_paste_stream<R>(
        &self,
        reader: R,
        syntax_highlight: Option<&str>,
    ) -> Result<CreatedPaste, Error>
    where
        R: Read + Send + 'static,
    {
        self.create_paste_body(Body::new(reader), syntax_highlight)
    }

    fn create_paste_body(
        &self,
        body: Body,
        syntax_highlight: Option<&str>,
    ) -> Result<CreatedPaste, Error> {
        let url = self.create_paste_url(syntax_highlight);
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

    fn create_paste_url(&self, syntax_highlight: Option<&str>) -> String {
        let url = format!("{}/api/v1/pastes", self.base_url);

        match syntax_highlight.filter(|syntax| !syntax.is_empty()) {
            Some(syntax_highlight) => {
                let mut url = reqwest::Url::parse(&url).expect("client base_url must be valid URL");
                url.query_pairs_mut()
                    .append_pair("syntax_highlight", syntax_highlight);
                url.into()
            }
            None => url,
        }
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

#[derive(Debug, Clone, Deserialize)]
pub struct Paste {
    pub data: String,
    pub syntax_highlight: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreatedPaste {
    pub id: String,
    pub syntax_highlight: String,
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
    Request { url: String, source: reqwest::Error },
    ReadResponse { url: String, source: reqwest::Error },
    Decode { source: serde_json::Error },
    Api(String),
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Request { url, .. } => write!(formatter, "failed to request paste from {url}"),
            Self::ReadResponse { url, .. } => {
                write!(formatter, "failed to read paste response from {url}")
            }
            Self::Decode { .. } => write!(formatter, "failed to decode paste response"),
            Self::Api(message) => formatter.write_str(message),
        }
    }
}

impl error::Error for Error {
    fn source(&self) -> Option<&(dyn error::Error + 'static)> {
        match self {
            Self::Request { source, .. } | Self::ReadResponse { source, .. } => Some(source),
            Self::Decode { source } => Some(source),
            Self::Api(_) => None,
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
        return Err(Error::Api(format_api_error(status, &body)));
    }

    decode_json(&body)
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
        None => format!("paste request failed: {status}"),
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

    #[test]
    fn client_trims_trailing_slash_from_base_url() {
        let client = Client::new("http://localhost:4000/");

        assert_eq!(client.base_url, "http://localhost:4000");
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
            client.create_paste_url(None),
            "http://localhost:4000/api/v1/pastes"
        );
        assert_eq!(
            client.create_paste_url(Some("")),
            "http://localhost:4000/api/v1/pastes"
        );
    }

    #[test]
    fn create_paste_url_adds_syntax_highlight_query_param() {
        let client = Client::new("http://localhost:4000/");

        assert_eq!(
            client.create_paste_url(Some("rust")),
            "http://localhost:4000/api/v1/pastes?syntax_highlight=rust"
        );
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

        assert_eq!(message, "paste request failed: 500 Internal Server Error");
    }

    #[test]
    fn decodes_create_response_metadata() {
        let response = decode_json::<CreateResponse>(
            r#"{"data":{"id":"00000000-0000-0000-0000-000000000000","syntax_highlight":"plain"}}"#,
        )
        .unwrap();

        assert_eq!(response.data.id, "00000000-0000-0000-0000-000000000000");
        assert_eq!(response.data.syntax_highlight, "plain");
    }
}
