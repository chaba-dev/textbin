mod create;
mod show;

use clap::Subcommand;

use crate::base::{create::CreateArgs, show::ShowArgs};

#[derive(Subcommand)]
pub enum Commands {
    /// Retrieve and print a paste
    Show(ShowArgs),
    /// Create a new paste
    Create(CreateArgs),
}

pub fn handle(command: &Commands) -> anyhow::Result<()> {
    match command {
        Commands::Show(args) => show::handle(args),
        Commands::Create(args) => create::handle(args),
    }
}
