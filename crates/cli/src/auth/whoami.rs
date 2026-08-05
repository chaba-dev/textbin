use anyhow::Result;

use crate::settings::Settings;

pub fn handle(settings: &Settings) -> Result<()> {
    let client = settings.client()?;
    let identity = client.identity()?;

    println!("{}", identity.user.email);
    println!("Server: {}", client.base_url());
    println!("Token: {} ({})", identity.token.name, identity.token.id);

    Ok(())
}
