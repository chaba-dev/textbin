use clap::Args;

#[derive(Args)]
pub struct CreateArgs {
    /// data to paste
    data: String,
}

pub fn handle(args: &CreateArgs) -> anyhow::Result<()> {
    println!("Creating a paste with data: {}", &args.data);

    Ok(())
}
