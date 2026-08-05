use anyhow::{Context, Result};
use clap::Args;
use lumis::formatters::TerminalBuilder;
use lumis::languages::Language;
use lumis::themes;
use std::io::{self, IsTerminal, Write};
use textbin_client::Paste;

use crate::settings::Settings;

#[derive(Args)]
pub struct ShowArgs {
    /// The identifier/UUID of the paste
    id: String,

    /// Disable color output
    #[arg(long, default_value_t = false)]
    no_color: bool,

    /// Write the paste exactly as stored, without highlighting or an added newline
    #[arg(long, default_value_t = false, conflicts_with = "no_color")]
    raw: bool,

    /// Open the paste in the default browser instead of printing it
    #[arg(long, default_value_t = false, conflicts_with = "no_color")]
    open: bool,
}

pub fn handle(args: &ShowArgs, settings: &Settings) -> Result<()> {
    if args.open {
        let client = settings.server_client()?;
        let url = if args.raw {
            client.raw_paste_url(&args.id)
        } else {
            client.paste_url(&args.id)
        };

        webbrowser::open(&url).with_context(|| format!("failed to open {url}"))?;
        println!("{url}");
        return Ok(());
    }

    let client = settings.client()?;
    let paste = client.get_paste(&args.id)?;

    if args.raw {
        write_raw(io::stdout().lock(), &paste.data)?;
        return Ok(());
    }

    let use_color = io::stdout().is_terminal() && !args.no_color;
    let body = render_paste(&paste, use_color)?;

    print_code_area(&body);

    Ok(())
}

fn write_raw(mut writer: impl Write, data: &str) -> io::Result<()> {
    writer.write_all(data.as_bytes())
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
            visibility: "private".to_string(),
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
    fn write_raw_preserves_content_without_adding_a_newline() {
        let mut output = Vec::new();

        write_raw(&mut output, "paste without newline").unwrap();

        assert_eq!(output, b"paste without newline");
    }

    #[test]
    fn write_raw_preserves_trailing_newlines() {
        let mut output = Vec::new();

        write_raw(&mut output, "paste\n\n").unwrap();

        assert_eq!(output, b"paste\n\n");
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
}
