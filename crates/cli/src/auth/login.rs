use anyhow::{Context, Result, anyhow};
use clap::Args;
use serde::Serialize;
use std::io::{self, Write};
use textbin_client::{ApiTokenMetadata, AuthenticatedUser, Client, Identity};

use crate::output::print_json;
use crate::settings::{Settings, environment_token};

#[derive(Args)]
pub struct LoginArgs {
    /// Textbin server URL
    #[arg(long)]
    server: Option<String>,

    /// Configuration profile to activate
    #[arg(long)]
    profile: Option<String>,

    /// Name assigned to a newly created API token
    #[arg(long, default_value = "Textbin CLI")]
    name: String,

    /// Import an existing API token through a hidden prompt
    #[arg(long)]
    with_token: bool,

    /// Print the outcome as JSON; prompts still go to the terminal
    #[arg(long, default_value_t = false)]
    json: bool,
}

/// How the profile came to be authenticated. The API token itself is never
/// printed; scripts that need it should pass it in through TEXTBIN_TOKEN.
#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum LoginStatus {
    LoggedIn,
    AlreadyLoggedIn,
    Environment,
}

#[derive(Serialize)]
struct LoginOutput<'a> {
    status: LoginStatus,
    profile: &'a str,
    server: &'a str,
    user: &'a AuthenticatedUser,
    token: &'a ApiTokenMetadata,
}

pub fn handle(args: &LoginArgs, settings: &Settings) -> Result<()> {
    let profile_name = args
        .profile
        .clone()
        .unwrap_or(settings.active_profile_name()?);
    settings.validate_profile_name(&profile_name)?;
    let server_url = match &args.server {
        Some(url) => Client::try_new(url)?.base_url().to_string(),
        None => settings.default_server_url(&profile_name)?,
    };

    if !args.with_token
        && let Some(token) = environment_token()
    {
        let client = Client::try_new(&server_url)?.with_api_token(Some(token));
        let identity = client.identity()?;
        settings.save_environment_login(&profile_name, &server_url, &identity)?;
        return report(
            args,
            LoginStatus::Environment,
            &profile_name,
            &server_url,
            &identity,
        );
    }

    if args.server.is_none()
        && !args.with_token
        && let Some(client) = settings.stored_client(&profile_name)?
    {
        match client.identity() {
            Ok(identity) => {
                settings.migrate_login(&profile_name, &identity)?;
                settings.activate_profile(&profile_name)?;
                return report(
                    args,
                    LoginStatus::AlreadyLoggedIn,
                    &profile_name,
                    client.base_url(),
                    &identity,
                );
            }
            Err(error) if error.unauthorized() => {
                settings.forget_login(&profile_name)?;
            }
            Err(error) => return Err(error.into()),
        }
    }

    let client = Client::try_new(&server_url)?;
    let (token, identity, newly_created) = if args.with_token {
        let token = rpassword::prompt_password("API token: ")?;
        let authenticated_client = client.clone().with_api_token(Some(token.clone()));
        let identity = authenticated_client.identity()?;
        (token, identity, false)
    } else {
        let email = prompt("Email: ")?;
        let password = rpassword::prompt_password("Password: ")?;
        let created = client.create_api_token(&email, &password, &args.name)?;
        let identity = created.identity();
        (created.api_token, identity, true)
    };

    if let Err(storage_error) = settings.save_login(&profile_name, &server_url, &identity, &token) {
        if newly_created {
            let authenticated_client = client.with_api_token(Some(token));

            return match authenticated_client.revoke_current_token() {
                Ok(()) => Err(storage_error.context(
                    "the newly created API token was revoked because it could not be stored",
                )),
                Err(cleanup_error) => Err(anyhow!(
                    "could not store the new API token and could not revoke token {}: {storage_error}; cleanup failed: {cleanup_error}",
                    identity.token.id
                )),
            };
        }

        return Err(storage_error);
    }

    report(
        args,
        LoginStatus::LoggedIn,
        &profile_name,
        &server_url,
        &identity,
    )
}

// Prompts go to stderr so stdout carries only the result, which `--json`
// relies on. rpassword already reads the password from the terminal.
fn prompt(label: &str) -> Result<String> {
    eprint!("{label}");
    io::stderr().flush().context("could not write prompt")?;

    let mut value = String::new();
    io::stdin()
        .read_line(&mut value)
        .context("could not read prompt")?;
    Ok(value.trim().to_string())
}

fn report(
    args: &LoginArgs,
    status: LoginStatus,
    profile: &str,
    server: &str,
    identity: &Identity,
) -> Result<()> {
    if args.json {
        return print_json(&LoginOutput {
            status,
            profile,
            server,
            user: &identity.user,
            token: &identity.token,
        });
    }

    let prefix = match status {
        LoginStatus::LoggedIn => "Logged in",
        LoginStatus::AlreadyLoggedIn => "Already logged in",
        LoginStatus::Environment => "Authenticated through TEXTBIN_TOKEN",
    };
    println!("{prefix} as {} on {server}", identity.user.email);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{TEST_ENVIRONMENT, initialize_mock_keyring};
    use std::fs;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::path::PathBuf;
    use std::thread;
    use std::time::{SystemTime, UNIX_EPOCH};
    use textbin_client::{ApiTokenMetadata, AuthenticatedUser, Identity};

    #[test]
    fn already_authenticated_profile_becomes_active() {
        let _environment = TEST_ENVIRONMENT.lock().unwrap();
        let environment_token = std::env::var_os("TEXTBIN_TOKEN");
        unsafe { std::env::remove_var("TEXTBIN_TOKEN") };
        initialize_mock_keyring();
        let path = temp_config_path();
        let settings = Settings::new(Some(path.clone())).unwrap();
        let (server_url, server) = identity_server();

        settings
            .save_login("demo", &server_url, &identity(), "demo-token")
            .unwrap();
        settings
            .save_login(
                "other",
                "https://other.example.com",
                &identity(),
                "other-token",
            )
            .unwrap();

        let result = handle(
            &LoginArgs {
                server: None,
                profile: Some("demo".to_string()),
                name: "Textbin CLI".to_string(),
                with_token: false,
                json: false,
            },
            &settings,
        );
        if let Some(token) = environment_token {
            unsafe { std::env::set_var("TEXTBIN_TOKEN", token) };
        }

        result.unwrap();
        server.join().unwrap();

        assert_eq!(settings.active_profile_name().unwrap(), "demo");
        assert_eq!(settings.profile("demo").unwrap().unwrap().url, server_url);

        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn json_output_names_the_outcome_without_the_secret() {
        let identity = identity();
        let output = serde_json::to_value(LoginOutput {
            status: LoginStatus::AlreadyLoggedIn,
            profile: "demo",
            server: "https://textbin.example.com",
            user: &identity.user,
            token: &identity.token,
        })
        .unwrap();

        assert_eq!(output["status"], "already_logged_in");
        assert_eq!(output["profile"], "demo");
        assert_eq!(output["user"]["email"], identity.user.email);
        assert_eq!(output["token"]["id"], identity.token.id);
        assert!(output["token"].get("api_token").is_none());
    }

    #[test]
    fn environment_token_profile_becomes_active() {
        let _environment = TEST_ENVIRONMENT.lock().unwrap();
        let environment_token = std::env::var_os("TEXTBIN_TOKEN");
        initialize_mock_keyring();
        let path = temp_config_path();
        let settings = Settings::new(Some(path.clone())).unwrap();
        let (server_url, server) = identity_server();

        settings
            .save_login(
                "other",
                "https://other.example.com",
                &identity(),
                "other-token",
            )
            .unwrap();
        unsafe { std::env::set_var("TEXTBIN_TOKEN", "environment-token") };

        let result = handle(
            &LoginArgs {
                server: Some(server_url.clone()),
                profile: Some("demo".to_string()),
                name: "Textbin CLI".to_string(),
                with_token: false,
                json: false,
            },
            &settings,
        );
        match environment_token {
            Some(token) => unsafe { std::env::set_var("TEXTBIN_TOKEN", token) },
            None => unsafe { std::env::remove_var("TEXTBIN_TOKEN") },
        }

        result.unwrap();
        server.join().unwrap();

        assert_eq!(settings.active_profile_name().unwrap(), "demo");
        assert_eq!(settings.profile("demo").unwrap().unwrap().url, server_url);

        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    fn identity_server() -> (String, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0; 2048];
            let _ = stream.read(&mut request).unwrap();
            let body = r#"{"data":{"user":{"id":"user-id","email":"user@example.com"},"token":{"id":"token-id","name":"Test token","inserted_at":"2026-08-04T00:00:00Z"}}}"#;
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .unwrap();
        });
        (url, server)
    }

    fn identity() -> Identity {
        Identity {
            user: AuthenticatedUser {
                id: "user-id".to_string(),
                email: "user@example.com".to_string(),
            },
            token: ApiTokenMetadata {
                id: "token-id".to_string(),
                name: "Test token".to_string(),
                inserted_at: "2026-08-04T00:00:00Z".to_string(),
            },
        }
    }

    fn temp_config_path() -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();

        std::env::temp_dir()
            .join(format!("textbin-login-{}-{nonce}", std::process::id()))
            .join("config.toml")
    }
}
