mod auth;
mod base;

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

    /// auth placeholder
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

    if let Some(conf) = cli.config.as_deref() {
        println!("Value for config: {}", conf.display());
    }

    // You can check for the existence of subcommands, and if found use their
    // matches just as you would the top level cmd
    match &cli.command {
        Some(Commands::Base(command)) => base::handle(command)?,
        Some(Commands::Auth(command)) => auth::handle(command)?,
        None => {}
    }

    Ok(())
}
