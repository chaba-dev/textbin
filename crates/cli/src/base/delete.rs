use crate::output::print_json;
use crate::settings::Settings;
use clap::Args;
use serde::Serialize;

#[derive(Args)]
pub struct DeleteArgs {
    /// The identifier/UUID of the paste
    id: String,

    /// Delete the paste for good instead of leaving it restorable
    #[arg(long, default_value_t = false)]
    permanent: bool,

    /// Print the outcome as JSON
    #[arg(long, default_value_t = false)]
    json: bool,
}

#[derive(Serialize)]
struct Deleted<'a> {
    id: &'a str,
    permanent: bool,
}

pub fn handle(args: &DeleteArgs, settings: &Settings) -> anyhow::Result<()> {
    let client = settings.client()?;
    client.delete_paste(&args.id)?;

    // Deleting is idempotent, so this also purges a paste that was already
    // removed earlier.
    if args.permanent {
        client.purge_paste(&args.id)?;
    }

    if args.json {
        return print_json(&Deleted {
            id: &args.id,
            permanent: args.permanent,
        });
    }

    if args.permanent {
        println!("Permanently deleted {}", args.id);
    } else {
        println!(
            "Deleted {}. Restore it with `textbin restore {}` before the recovery window ends.",
            args.id, args.id
        );
    }

    Ok(())
}
