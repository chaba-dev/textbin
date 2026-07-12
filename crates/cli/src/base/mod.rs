mod create;
mod show;

use clap::Subcommand;

use crate::base::show::ShowArgs;

#[derive(Subcommand)]
pub enum Commands {
    /// Retrieve and print a paste
    Show(ShowArgs),
    /// Create a new paste
    Create {
        /// data to paste.
        data: String,
    },
}

pub fn handle(command: &Commands) -> anyhow::Result<()> {
    match command {
        Commands::Show(args) => show::handle(args),
        Commands::Create { data } => create::handle(data),
    }
}
