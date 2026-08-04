mod create;
mod delete;
mod show;

use clap::Subcommand;

use crate::base::{create::CreateArgs, delete::DeleteArgs, show::ShowArgs};
use crate::settings::Settings;

#[derive(Subcommand)]
pub enum Commands {
    /// Retrieve and print a paste
    Show(ShowArgs),
    /// Create a new paste
    Create(CreateArgs),
    /// Delete a paste
    Delete(DeleteArgs),
}

pub fn handle(command: &Commands, settings: &Settings) -> anyhow::Result<()> {
    match command {
        Commands::Show(args) => show::handle(args, settings),
        Commands::Create(args) => create::handle(args, settings),
        Commands::Delete(args) => delete::handle(args, settings),
    }
}
