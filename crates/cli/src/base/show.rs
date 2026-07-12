use anyhow::{Context, Result};
use serde::Deserialize;

const DEFAULT_TEXTBIN_URL: &str = "http://localhost:4000";

#[derive(Deserialize)]
struct ShowResponse {
    data: Paste,
}

#[derive(Deserialize)]
struct Paste {
    data: String,
}

pub fn handle(id: &str) -> Result<()> {
    let base_url = std::env::var("TEXTBIN_URL").unwrap_or_else(|_| DEFAULT_TEXTBIN_URL.to_string());
    let url = format!("{}/api/v1/pastes/{id}", base_url.trim_end_matches('/'));

    let response: ShowResponse = reqwest::blocking::get(&url)
        .with_context(|| format!("failed to request paste from {url}"))?
        .error_for_status()
        .with_context(|| format!("paste request failed for {url}"))?
        .json()
        .context("failed to decode paste response")?;

    println!("{}", response.data.data);

    Ok(())
}
