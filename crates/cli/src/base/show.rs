use anyhow::{Context, Result, bail};
use clap::Args;
use lumis::formatters::TerminalBuilder;
use lumis::languages::Language;
use lumis::themes;
use reqwest::StatusCode;
use serde::Deserialize;
use std::collections::BTreeMap;
use std::io::{self, IsTerminal};

const DEFAULT_TEXTBIN_URL: &str = "http://localhost:4000";

#[derive(Args)]
pub struct ShowArgs {
    /// The identifier/uuid of the paste
    id: String,

    /// disable color output
    #[arg(long, default_value_t = false)]
    no_color: bool,
}

#[derive(Deserialize)]
struct ShowResponse {
    data: Paste,
}

#[derive(Deserialize)]
struct ApiErrorResponse {
    errors: ApiErrors,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum ApiErrors {
    Detail { detail: String },
    Fields(BTreeMap<String, Vec<String>>),
}

#[derive(Deserialize)]
struct Paste {
    data: String,
    syntax_highlight: String,
}

pub fn handle(args: &ShowArgs) -> Result<()> {
    let base_url = std::env::var("TEXTBIN_URL").unwrap_or_else(|_| DEFAULT_TEXTBIN_URL.to_string());
    let url = format!(
        "{}/api/v1/pastes/{}",
        base_url.trim_end_matches('/'),
        args.id,
    );

    let response = reqwest::blocking::get(&url)
        .with_context(|| format!("failed to request paste from {url}"))?;

    let status = response.status();
    let body = response
        .text()
        .with_context(|| format!("failed to read paste response from {url}"))?;

    if !status.is_success() {
        bail!("{}", format_api_error(status, &body));
    }

    let response: ShowResponse =
        serde_json::from_str(&body).context("failed to decode paste response")?;

    let paste = &response.data;

    let use_color = io::stdout().is_terminal() && !args.no_color;
    let body = render_paste(paste, use_color)?;

    print_code_area(&body);

    Ok(())
}

fn print_code_area(content: &str) {
    print!("{}", format_code_area(content));
}

fn format_code_area(content: &str) -> String {
    if !content.ends_with('\n') {
        format!("{content}\n")
    } else {
        content.to_string()
    }
}

fn render_paste(paste: &Paste, use_color: bool) -> Result<String> {
    if use_color {
        highlight_paste(paste)
    } else {
        Ok(paste.data.clone())
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

fn highlight_paste(paste: &Paste) -> Result<String> {
    let language = Language::guess(Some(&paste.syntax_highlight), &paste.data);
    let theme = themes::get("onedark").context("failed to load Lumis theme: onedark")?;
    let formatter = TerminalBuilder::new()
        .language(language)
        .theme(Some(theme))
        .build()
        .context("failed to build terminal syntax highlighter")?;

    Ok(lumis::highlight(&paste.data, formatter))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paste(data: &str, syntax_highlight: &str) -> Paste {
        Paste {
            data: data.to_string(),
            syntax_highlight: syntax_highlight.to_string(),
        }
    }

    #[test]
    fn format_code_area_appends_missing_trailing_newline() {
        assert_eq!(format_code_area("hello"), "hello\n");
    }

    #[test]
    fn format_code_area_preserves_existing_trailing_newline() {
        assert_eq!(format_code_area("hello\n"), "hello\n");
    }

    #[test]
    fn render_paste_without_color_returns_raw_data() {
        let paste = paste("fn main() {}\n", "rust");

        assert_eq!(render_paste(&paste, false).unwrap(), "fn main() {}\n");
    }

    #[test]
    fn render_paste_with_color_returns_terminal_highlighted_data() {
        let paste = paste("fn main() {}\n", "rust");
        let rendered = render_paste(&paste, true).unwrap();

        assert!(rendered.contains("\u{1b}["));
        assert!(rendered.contains("fn"));
        assert!(rendered.contains("main"));
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
