use crate::output::print_json;
use crate::settings::Settings;
use clap::Args;

#[derive(Args)]
pub struct RestoreArgs {
    /// The identifier/UUID of the deleted or expired paste
    id: String,

    /// Print the restored paste's metadata as JSON instead of its link
    #[arg(long, default_value_t = false)]
    json: bool,
}

pub fn handle(args: &RestoreArgs, settings: &Settings) -> anyhow::Result<()> {
    let client = settings.client()?;
    let paste = client.restore_paste(&args.id)?;

    if args.json {
        return print_json(&paste);
    }

    let url = paste
        .url
        .clone()
        .unwrap_or_else(|| client.paste_url(&paste.id));
    println!("Restored {url}");
    Ok(())
}
