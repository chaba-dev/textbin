use clap::Subcommand;

#[derive(Subcommand)]
pub enum Commands {
    /// Login into textbin app
    Login,
    /// Logout of textbin app
    Logout,
}
