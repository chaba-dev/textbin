use clap::Args;
use textbin_client::Client;

#[derive(Args)]
pub struct DeleteArgs {
    /// The identifier/UUID of the paste
    id: String,
}

pub fn handle(args: &DeleteArgs) -> anyhow::Result<()> {
    let client = Client::from_env();
    client.delete_paste(&args.id)?;

    println!("Deleted {}", client.paste_url(&args.id));
    Ok(())
}
