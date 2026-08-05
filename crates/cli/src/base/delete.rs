use crate::settings::Settings;
use clap::Args;

#[derive(Args)]
pub struct DeleteArgs {
    /// The identifier/UUID of the paste
    id: String,
}

pub fn handle(args: &DeleteArgs, settings: &Settings) -> anyhow::Result<()> {
    let client = settings.client()?;
    client.delete_paste(&args.id)?;

    println!("Deleted {}", client.paste_url(&args.id));
    Ok(())
}
