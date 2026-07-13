use clap::Args;
use std::fs;
use std::io::{self, BufReader, IsTerminal};
use std::path::PathBuf;
use textbin_client::Client;

#[derive(Args)]
pub struct CreateArgs {
    /// Accepts static strings and stdin inputs including pipes.
    /// When given a string with a '@' prefix, it'll treat it as a file and will attempt
    /// to read the data from the file, essentially the same as `cat <file> | textbin create`
    data: Option<String>,
}

pub fn handle(args: &CreateArgs) -> anyhow::Result<()> {
    let client = Client::from_env();

    let paste = match &args.data {
        Some(data) => match create_data_from_arg(data)? {
            Data::File(path) => {
                // stream from the file to API
                let file = fs::File::open(path)?;
                let reader = BufReader::new(file);

                client.create_paste_stream(reader)?
            }
            Data::Literal(data) => client.create_paste(data)?,
        },
        None => {
            // If stdin is still the interactive terminal, reading from it would
            // look like the command hung while waiting for EOF. When stdin is
            // not a terminal, it may be a pipe, redirected file, heredoc, or
            // another non-interactive source; all of those can be streamed.
            if io::stdin().is_terminal() {
                anyhow::bail!("provide paste data as an argument or pipe it on stdin");
            }

            client.create_paste_stream(io::stdin())?
        }
    };

    println!("{}", paste.id);
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
enum Data {
    File(PathBuf),
    Literal(String),
}

fn create_data_from_arg(data: &str) -> anyhow::Result<Data> {
    match data.strip_prefix('@') {
        Some(path) => match fs::exists(path) {
            Ok(true) => Ok(Data::File(PathBuf::from(path))),
            Ok(false) => anyhow::bail!("file does not exist at path {}", path),
            Err(err) => anyhow::bail!("error checking path: {}", err),
        },
        None => Ok(Data::Literal(data.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn create_data_from_arg_treats_plain_data_as_literal() {
        assert_eq!(
            create_data_from_arg("hello world").unwrap(),
            Data::Literal("hello world".to_string())
        );
    }

    #[test]
    fn create_data_from_arg_treats_existing_at_path_as_file() {
        let path = temp_file_path("create-data-file");
        fs::write(&path, "hello from file").unwrap();

        let result = create_data_from_arg(&format!("@{}", path.display()));

        fs::remove_file(&path).unwrap();
        assert_eq!(result.unwrap(), Data::File(path));
    }

    #[test]
    fn create_data_from_arg_errors_when_at_path_does_not_exist() {
        let path = temp_file_path("missing-create-data-file");
        let result = create_data_from_arg(&format!("@{}", path.display()));

        assert_eq!(
            result.unwrap_err().to_string(),
            format!("file does not exist at path {}", path.display())
        );
    }

    fn temp_file_path(label: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();

        std::env::temp_dir().join(format!("textbin-{label}-{}-{nonce}", std::process::id()))
    }
}
