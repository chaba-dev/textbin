use anyhow::{Context, Result, anyhow};
use clap::Args;
use std::io::{self, Write};
use textbin_client::Client;

use crate::settings::{Settings, environment_token};

#[derive(Args)]
pub struct LoginArgs {
    /// Textbin server URL
    #[arg(long)]
    server: Option<String>,

    /// Configuration profile to activate
    #[arg(long)]
    profile: Option<String>,

    /// Name assigned to a newly created API token
    #[arg(long, default_value = "Textbin CLI")]
    name: String,

    /// Import an existing API token through a hidden prompt
    #[arg(long)]
    with_token: bool,
}

pub fn handle(args: &LoginArgs, settings: &Settings) -> Result<()> {
    let profile_name = args
        .profile
        .clone()
        .unwrap_or(settings.active_profile_name()?);
    settings.validate_profile_name(&profile_name)?;
    let server_url = match &args.server {
        Some(url) => Client::try_new(url)?.base_url().to_string(),
        None => settings.default_server_url(&profile_name)?,
    };

    if !args.with_token
        && let Some(token) = environment_token()
    {
        let client = Client::try_new(&server_url)?.with_api_token(Some(token));
        let identity = client.identity()?;
        print_identity(
            "Authenticated through TEXTBIN_TOKEN",
            &server_url,
            &identity.user.email,
        );
        return Ok(());
    }

    if args.server.is_none()
        && !args.with_token
        && let Some(client) = settings.stored_client(&profile_name)?
    {
        match client.identity() {
            Ok(identity) => {
                print_identity("Already logged in", client.base_url(), &identity.user.email);
                return Ok(());
            }
            Err(error) if error.unauthorized() => {
                settings.forget_login(&profile_name)?;
            }
            Err(error) => return Err(error.into()),
        }
    }

    let client = Client::try_new(&server_url)?;
    let (token, identity, newly_created) = if args.with_token {
        let token = rpassword::prompt_password("API token: ")?;
        let authenticated_client = client.clone().with_api_token(Some(token.clone()));
        let identity = authenticated_client.identity()?;
        (token, identity, false)
    } else {
        let email = prompt("Email: ")?;
        let password = rpassword::prompt_password("Password: ")?;
        let created = client.create_api_token(&email, &password, &args.name)?;
        let identity = created.identity();
        (created.api_token, identity, true)
    };

    if let Err(storage_error) = settings.save_login(&profile_name, &server_url, &identity, &token) {
        if newly_created {
            let authenticated_client = client.with_api_token(Some(token));

            return match authenticated_client.revoke_current_token() {
                Ok(()) => Err(storage_error.context(
                    "the newly created API token was revoked because it could not be stored",
                )),
                Err(cleanup_error) => Err(anyhow!(
                    "could not store the new API token and could not revoke token {}: {storage_error}; cleanup failed: {cleanup_error}",
                    identity.token.id
                )),
            };
        }

        return Err(storage_error);
    }

    print_identity("Logged in", &server_url, &identity.user.email);

    Ok(())
}

fn prompt(label: &str) -> Result<String> {
    print!("{label}");
    io::stdout().flush().context("could not write prompt")?;

    let mut value = String::new();
    io::stdin()
        .read_line(&mut value)
        .context("could not read prompt")?;
    Ok(value.trim().to_string())
}

fn print_identity(prefix: &str, server_url: &str, email: &str) {
    println!("{prefix} as {email} on {server_url}");
}
