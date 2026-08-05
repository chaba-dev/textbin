mod auth;
mod base;
mod settings;

use std::path::PathBuf;

use anyhow::Result;
use clap::{CommandFactory, Parser, Subcommand};

#[derive(Parser)]
#[command(version, about, long_about = None)]
struct TextbinCli {
    #[arg(short, long)]
    config: Option<PathBuf>,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    #[command(flatten)]
    Base(base::Commands),

    /// Manage CLI authentication
    #[command(subcommand)]
    Auth(auth::Commands),
}

fn main() -> Result<()> {
    if std::env::args_os().len() == 1 {
        TextbinCli::command().print_help()?;
        println!();
        return Ok(());
    }

    let cli = TextbinCli::parse();

    let settings = settings::Settings::new(cli.config)?;

    // You can check for the existence of subcommands, and if found use their
    // matches just as you would the top level cmd
    match &cli.command {
        Some(Commands::Base(command)) => base::handle(command, &settings)?,
        Some(Commands::Auth(command)) => auth::handle(command, &settings)?,
        None => {}
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn show_accepts_raw_and_open_together() {
        let result = TextbinCli::try_parse_from([
            "textbin",
            "show",
            "00000000-0000-0000-0000-000000000000",
            "--raw",
            "--open",
        ]);

        assert!(result.is_ok());
    }

    #[test]
    fn show_rejects_no_color_with_browser_output() {
        let result = TextbinCli::try_parse_from([
            "textbin",
            "show",
            "00000000-0000-0000-0000-000000000000",
            "--no-color",
            "--open",
        ]);

        assert!(result.is_err());
    }

    #[test]
    fn parses_auth_workflows() {
        assert!(TextbinCli::try_parse_from(["textbin", "auth", "whoami"]).is_ok());
        assert!(
            TextbinCli::try_parse_from([
                "textbin",
                "auth",
                "login",
                "--server",
                "https://demo.textbin.com",
                "--profile",
                "demo",
                "--with-token",
            ])
            .is_ok()
        );
        assert!(
            TextbinCli::try_parse_from([
                "textbin",
                "auth",
                "logout",
                "--profile",
                "demo",
                "--revoke",
            ])
            .is_ok()
        );
    }
}
