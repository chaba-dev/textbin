mod login;
mod logout;

use clap::Subcommand;

#[derive(Subcommand)]
pub enum Commands {
    /// Login into textbin app
    Login,
    /// Logout of textbin app
    Logout,
}

pub fn handle(command: &Commands) {
    match command {
        Commands::Login => login::handle(),
        Commands::Logout => logout::handle(),
    }
}
