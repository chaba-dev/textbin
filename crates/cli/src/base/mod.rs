mod create;
mod delete;
mod deleted;
mod output;
mod restore;
mod show;

use clap::Subcommand;

use crate::base::{
    create::CreateArgs, delete::DeleteArgs, deleted::DeletedArgs, restore::RestoreArgs,
    show::ShowArgs,
};
use crate::settings::Settings;

#[derive(Subcommand)]
pub enum Commands {
    /// Retrieve and print a paste
    Show(ShowArgs),
    /// Create a new paste
    Create(CreateArgs),
    /// Delete a paste; it stays restorable for the workspace's recovery window
    Delete(DeleteArgs),
    /// List deleted and expired pastes that can still be restored
    Deleted(DeletedArgs),
    /// Restore a deleted or expired paste
    Restore(RestoreArgs),
}

pub fn handle(command: &Commands, settings: &Settings) -> anyhow::Result<()> {
    match command {
        Commands::Show(args) => show::handle(args, settings),
        Commands::Create(args) => create::handle(args, settings),
        Commands::Delete(args) => delete::handle(args, settings),
        Commands::Deleted(args) => deleted::handle(args, settings),
        Commands::Restore(args) => restore::handle(args, settings),
    }
}
