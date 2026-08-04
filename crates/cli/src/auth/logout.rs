use anyhow::{Context, Result, bail};
use clap::Args;

use crate::settings::{Settings, environment_token};

#[derive(Args)]
pub struct LogoutArgs {
    /// Revoke the current API token on the server before removing it locally
    #[arg(long)]
    revoke: bool,

    /// Configuration profile to log out
    #[arg(long)]
    profile: Option<String>,
}

pub fn handle(args: &LogoutArgs, settings: &Settings) -> Result<()> {
    let profile_name = args
        .profile
        .clone()
        .unwrap_or(settings.active_profile_name()?);
    settings.validate_profile_name(&profile_name)?;

    if args.revoke {
        let client = if environment_token().is_some() {
            settings.client()?
        } else {
            settings
                .stored_client(&profile_name)?
                .context("profile is not authenticated; run `textbin auth login`")?
        };
        client.revoke_current_token()?;
        println!("Revoked the API token on {}", client.base_url());
    }

    let removed = settings.forget_login(&profile_name)?;
    let environment_token_set = environment_token().is_some();

    if environment_token_set {
        if args.revoke {
            println!("TEXTBIN_TOKEN is still set but now references a revoked token");
            return Ok(());
        }

        bail!("TEXTBIN_TOKEN is still set; unset it to complete logout")
    }

    if removed {
        println!("Logged out of profile {profile_name}");
    } else {
        println!("Profile {profile_name} was not logged in");
    }

    Ok(())
}
