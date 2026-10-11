use anyhow::Result;
use serde::Serialize;

/// Prints a value as one line of JSON. Commands with `--json` write only this
/// to stdout so scripts can parse it; human messages go elsewhere or not at all.
pub fn print_json(value: &impl Serialize) -> Result<()> {
    println!("{}", serde_json::to_string(value)?);
    Ok(())
}
