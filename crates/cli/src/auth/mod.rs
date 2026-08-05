mod login;
mod logout;
mod whoami;

use clap::Subcommand;

use crate::settings::Settings;

#[derive(Subcommand)]
pub enum Commands {
    /// Log in to a Textbin server
    Login(login::LoginArgs),
    /// Log out of a Textbin server
    Logout(logout::LogoutArgs),
    /// Show the authenticated account
    Whoami,
}

pub fn handle(command: &Commands, settings: &Settings) -> anyhow::Result<()> {
    match command {
        Commands::Login(args) => login::handle(args, settings),
        Commands::Logout(args) => logout::handle(args, settings),
        Commands::Whoami => whoami::handle(settings),
    }
}
