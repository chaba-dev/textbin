mod create;
mod show;

use clap::Subcommand;

#[derive(Subcommand)]
pub enum Commands {
    /// Retrieve and print a paste
    Show,
    /// Create a new paste
    Create {
        /// data to paste.
        #[arg(value_name = "DATA")]
        data: String,
    },
}

pub fn handle(command: &Commands) {
    match command {
        Commands::Show => show::handle(),
        Commands::Create { data } => create::handle(data),
    }
}
