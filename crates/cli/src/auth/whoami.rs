use anyhow::Result;
use clap::Args;
use serde::Serialize;
use textbin_client::{ApiTokenMetadata, AuthenticatedUser};

use crate::output::print_json;
use crate::settings::Settings;

#[derive(Args)]
pub struct WhoamiArgs {
    /// Print the account, server and token as JSON
    #[arg(long, default_value_t = false)]
    json: bool,
}

#[derive(Serialize)]
struct WhoamiOutput<'a> {
    server: &'a str,
    user: &'a AuthenticatedUser,
    token: &'a ApiTokenMetadata,
}

pub fn handle(args: &WhoamiArgs, settings: &Settings) -> Result<()> {
    let client = settings.client()?;
    let identity = client.identity()?;

    if args.json {
        return print_json(&WhoamiOutput {
            server: client.base_url(),
            user: &identity.user,
            token: &identity.token,
        });
    }

    println!("{}", identity.user.email);
    println!("Server: {}", client.base_url());
    println!("Token: {} ({})", identity.token.name, identity.token.id);

    Ok(())
}
