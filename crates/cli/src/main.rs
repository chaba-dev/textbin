mod auth;
mod base;

use std::path::PathBuf;

use clap::{ArgAction, Parser, Subcommand};

#[derive(Parser)]
#[command(version, about, long_about = None)]
struct TextbinCli {
    name: Option<String>,

    #[arg(short, long, value_name = "FILE")]
    config: Option<PathBuf>,

    #[arg(short, long, action = ArgAction::Count)]
    debug: u8,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    #[command(flatten)]
    Base(base::Commands),

    #[command(subcommand)]
    Auth(auth::Commands),
}

fn main() {
    let cli = TextbinCli::parse();

    if let Some(name) = cli.name.as_deref() {
        println!("Value for name: {name}");
    }

    if let Some(conf) = cli.config.as_deref() {
        println!("Value for config: {}", conf.display());
    }

    // You can see how many times a particular flag or argument occurred
    // Note, only flags can have multiple occurrences
    match cli.debug {
        0 => println!("Debug mode is off"),
        1 => println!("Debug mode is kind of on"),
        2 => println!("Debug mode is on"),
        _ => println!("Don't be crazy"),
    }

    // You can check for the existence of subcommands, and if found use their
    // matches just as you would the top level cmd
    match &cli.command {
        Some(Commands::Base(base::Commands::Get)) => {
            println!("Retrieving a paste...");
        }
        Some(Commands::Base(base::Commands::Create { data })) => {
            println!("Creating a paste with data: {data}");
        }
        Some(Commands::Auth(auth::Commands::Login)) => {
            println!("Logging in...");
        }
        Some(Commands::Auth(auth::Commands::Logout)) => {
            println!("Logging out...");
        }
        None => {}
    }
}
