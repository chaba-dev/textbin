use crate::base::output::print_json;
use crate::settings::Settings;
use clap::Args;
use textbin_client::RemovedPaste;

#[derive(Args)]
pub struct DeletedArgs {
    /// Print the list as a JSON array
    #[arg(long, default_value_t = false)]
    json: bool,
}

pub fn handle(args: &DeletedArgs, settings: &Settings) -> anyhow::Result<()> {
    let client = settings.client()?;
    let pastes = client.list_removed_pastes()?;

    if args.json {
        return print_json(&pastes);
    }

    if pastes.is_empty() {
        println!("Nothing deleted.");
        return Ok(());
    }

    for paste in &pastes {
        println!("{}", format_row(paste));
    }

    Ok(())
}

fn format_row(paste: &RemovedPaste) -> String {
    let title = paste.title.as_deref().unwrap_or("Untitled paste");
    let purge_after = paste
        .purge_after
        .as_deref()
        .and_then(|timestamp| timestamp.get(..10))
        .unwrap_or("unknown");

    format!(
        "{}  {:<8}  purged after {}  {}",
        paste.id, paste.removal_reason, purge_after, title
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_row_shows_id_reason_purge_date_and_title() {
        let paste = RemovedPaste {
            id: "p1".to_string(),
            title: Some("Deploy log".to_string()),
            url: None,
            removal_reason: "deleted".to_string(),
            removed_at: Some("2026-10-10T08:00:00.000Z".to_string()),
            purge_after: Some("2026-11-09T08:00:00.000Z".to_string()),
        };

        assert_eq!(
            format_row(&paste),
            "p1  deleted   purged after 2026-11-09  Deploy log"
        );
    }

    #[test]
    fn format_row_names_untitled_pastes() {
        let paste = RemovedPaste {
            id: "p2".to_string(),
            title: None,
            url: None,
            removal_reason: "expired".to_string(),
            removed_at: None,
            purge_after: None,
        };

        assert!(format_row(&paste).ends_with("purged after unknown  Untitled paste"));
    }
}
