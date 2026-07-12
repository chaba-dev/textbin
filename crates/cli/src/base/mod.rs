mod create;
mod show;

use clap::Subcommand;

#[derive(Subcommand)]
pub enum Commands {
    /// Retrieve and print a paste
    Show {
        /// The identifier/uuid of the paste
        id: String,
    },
    /// Create a new paste
    Create {
        /// data to paste.
        data: String,
    },
}

pub fn handle(command: &Commands) -> anyhow::Result<()> {
    match command {
        Commands::Show { id } => show::handle(id),
        Commands::Create { data } => create::handle(data),
    }
}
