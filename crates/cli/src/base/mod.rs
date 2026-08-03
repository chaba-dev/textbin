mod create;
mod delete;
mod show;

use clap::Subcommand;

use crate::base::{create::CreateArgs, delete::DeleteArgs, show::ShowArgs};

#[derive(Subcommand)]
pub enum Commands {
    /// Retrieve and print a paste
    Show(ShowArgs),
    /// Create a new paste
    Create(CreateArgs),
    /// Delete a paste
    Delete(DeleteArgs),
}

pub fn handle(command: &Commands) -> anyhow::Result<()> {
    match command {
        Commands::Show(args) => show::handle(args),
        Commands::Create(args) => create::handle(args),
        Commands::Delete(args) => delete::handle(args),
    }
}
