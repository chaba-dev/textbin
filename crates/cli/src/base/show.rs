use anyhow::{Context, Result};
use clap::Args;
use lumis::formatters::TerminalBuilder;
use lumis::languages::Language;
use lumis::themes;
use serde::Deserialize;
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
struct Paste {
    data: String,
    syntax_highlight: String,
}

pub fn handle(args: &ShowArgs) -> Result<()> {
    let base_url = std::env::var("TEXTBIN_URL").unwrap_or_else(|_| DEFAULT_TEXTBIN_URL.to_string());
    let url = format!(
        "{}/api/v1/pastes/{}",
        base_url.trim_end_matches('/'),
        &args.id,
    );

    let response: ShowResponse = reqwest::blocking::get(&url)
        .with_context(|| format!("failed to request paste from {url}"))?
        .error_for_status()
        .with_context(|| format!("paste request failed for {url}"))?
        .json()
        .context("failed to decode paste response")?;

    let paste = &response.data;

    let use_color = io::stdout().is_terminal() && !args.no_color;
    let body = if use_color {
        highlight_paste(paste)?
    } else {
        paste.data.clone()
    };

    print_code_area(&body);

    Ok(())
}

fn print_code_area(content: &str) {
    print!("{content}");
    if !content.ends_with('\n') {
        println!();
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
