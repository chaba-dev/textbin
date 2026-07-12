use reqwest::StatusCode;
use serde::Deserialize;
use std::collections::BTreeMap;
use std::error;
use std::fmt;

const DEFAULT_TEXTBIN_URL: &str = "http://localhost:4000";

#[derive(Debug, Clone)]
pub struct Client {
    base_url: String,
}

impl Client {
    pub fn from_env() -> Self {
        let base_url =
            std::env::var("TEXTBIN_URL").unwrap_or_else(|_| DEFAULT_TEXTBIN_URL.to_string());

        Self::new(base_url)
    }

    pub fn new(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into().trim_end_matches('/').to_string(),
        }
    }

    pub fn get_paste(&self, id: &str) -> Result<Paste, Error> {
        let url = format!("{}/api/v1/pastes/{id}", self.base_url);
        let response = reqwest::blocking::get(&url).map_err(|source| Error::Request {
            url: url.clone(),
            source,
        })?;

        let status = response.status();
        let body = response.text().map_err(|source| Error::ReadResponse {
            url: url.clone(),
            source,
        })?;

        if !status.is_success() {
            return Err(Error::Api(format_api_error(status, &body)));
        }

        let response = serde_json::from_str::<ShowResponse>(&body)
            .map_err(|source| Error::Decode { source })?;

        Ok(response.data)
    }
}

#[derive(Debug, Deserialize)]
struct ShowResponse {
    data: Paste,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Paste {
    pub data: String,
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
}
