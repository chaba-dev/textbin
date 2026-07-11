use clap::Subcommand;

#[derive(Subcommand)]
pub enum Commands {
    /// Retrieve a paste
    Get,
    /// Create a new paste
    Create {
        /// data to paste.
        #[arg(value_name = "DATA")]
        data: String,
    },
}
