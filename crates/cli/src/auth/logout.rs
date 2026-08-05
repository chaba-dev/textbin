use anyhow::{Context, Result, bail};
use clap::Args;
use textbin_client::Client;

use crate::settings::{Settings, environment_token};

#[derive(Args)]
pub struct LogoutArgs {
    /// Revoke the current API token on the server before removing it locally
    #[arg(long)]
    revoke: bool,

    /// Configuration profile to log out
    #[arg(long)]
    profile: Option<String>,
}

pub fn handle(args: &LogoutArgs, settings: &Settings) -> Result<()> {
    if let Some(token) = environment_token() {
        if !args.revoke {
            bail!("TEXTBIN_TOKEN is still set; unset it to complete logout")
        }

        let server_url = match std::env::var("TEXTBIN_URL") {
            Ok(url) => url,
            Err(_) => {
                let profile_name = args
                    .profile
                    .clone()
                    .unwrap_or(settings.active_profile_name()?);
                settings.validate_profile_name(&profile_name)?;
                settings.default_server_url(&profile_name)?
            }
        };
        let client = Client::try_new(server_url)?.with_api_token(Some(token));
        client.revoke_current_token()?;
        println!("Revoked the API token on {}", client.base_url());
        println!("TEXTBIN_TOKEN is still set but now references a revoked token");
        return Ok(());
    }

    let profile_name = args
        .profile
        .clone()
        .unwrap_or(settings.active_profile_name()?);
    settings.validate_profile_name(&profile_name)?;

    if args.revoke {
        let client = settings
            .stored_client(&profile_name)?
            .context("profile is not authenticated; run `textbin auth login`")?;
        client.revoke_current_token()?;
        println!("Revoked the API token on {}", client.base_url());
    }

    let removed = settings.forget_login(&profile_name)?;

    if removed {
        println!("Logged out of profile {profile_name}");
    } else {
        println!("Profile {profile_name} was not logged in");
    }

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
    use std::sync::mpsc;
    use std::thread;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};
    use textbin_client::{ApiTokenMetadata, AuthenticatedUser, Identity};

    #[test]
    fn environment_token_is_revoked_on_the_selected_profiles_server() {
        let _environment = TEST_ENVIRONMENT.lock().unwrap();
        let environment_token = std::env::var_os("TEXTBIN_TOKEN");
        initialize_mock_keyring();
        let path = temp_config_path();
        let settings = Settings::new(Some(path.clone())).unwrap();
        let (sender, receiver) = mpsc::channel();
        let (demo_url, demo_server, stop_demo_server) = revoke_server("demo", sender.clone());
        let (other_url, other_server, stop_other_server) = revoke_server("other", sender);

        settings
            .save_login("demo", &demo_url, &identity(), "stored-demo-token")
            .unwrap();
        settings
            .save_login("other", &other_url, &identity(), "stored-other-token")
            .unwrap();

        unsafe { std::env::set_var("TEXTBIN_TOKEN", "environment-token") };
        let result = handle(
            &LogoutArgs {
                revoke: true,
                profile: Some("demo".to_string()),
            },
            &settings,
        );
        match environment_token {
            Some(token) => unsafe { std::env::set_var("TEXTBIN_TOKEN", token) },
            None => unsafe { std::env::remove_var("TEXTBIN_TOKEN") },
        }

        result.unwrap();
        assert_eq!(
            receiver.recv_timeout(Duration::from_secs(1)).unwrap(),
            "demo"
        );
        let profile = settings.profile("demo").unwrap().unwrap();
        assert!(settings.stored_client("demo").unwrap().is_some());
        assert_eq!(profile.url, demo_url);

        let _ = stop_demo_server.send(());
        let _ = stop_other_server.send(());
        demo_server.join().unwrap();
        other_server.join().unwrap();
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn environment_token_prevents_local_logout_before_profile_is_changed() {
        let _environment = TEST_ENVIRONMENT.lock().unwrap();
        let environment_token = std::env::var_os("TEXTBIN_TOKEN");
        initialize_mock_keyring();
        let path = temp_config_path();
        let settings = Settings::new(Some(path.clone())).unwrap();
        settings
            .save_login(
                "demo",
                "https://demo.example.com",
                &identity(),
                "stored-demo-token",
            )
            .unwrap();
        unsafe { std::env::set_var("TEXTBIN_TOKEN", "environment-token") };

        let result = handle(
            &LogoutArgs {
                revoke: false,
                profile: Some("demo".to_string()),
            },
            &settings,
        );

        match environment_token {
            Some(token) => unsafe { std::env::set_var("TEXTBIN_TOKEN", token) },
            None => unsafe { std::env::remove_var("TEXTBIN_TOKEN") },
        }
        assert!(result.is_err());
        assert!(settings.stored_client("demo").unwrap().is_some());
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn environment_logout_ignores_malformed_config_when_fully_configured() {
        let _environment = TEST_ENVIRONMENT.lock().unwrap();
        let old_url = std::env::var_os("TEXTBIN_URL");
        let old_token = std::env::var_os("TEXTBIN_TOKEN");
        let path = temp_config_path();
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "not valid toml = [").unwrap();
        let settings = Settings::new(Some(path.clone())).unwrap();
        let (sender, receiver) = mpsc::channel();
        let (server_url, server, stop_server) = revoke_server("environment", sender);
        unsafe {
            std::env::set_var("TEXTBIN_URL", server_url);
            std::env::set_var("TEXTBIN_TOKEN", "environment-token");
        }

        let result = handle(
            &LogoutArgs {
                revoke: true,
                profile: None,
            },
            &settings,
        );

        match old_url {
            Some(url) => unsafe { std::env::set_var("TEXTBIN_URL", url) },
            None => unsafe { std::env::remove_var("TEXTBIN_URL") },
        }
        match old_token {
            Some(token) => unsafe { std::env::set_var("TEXTBIN_TOKEN", token) },
            None => unsafe { std::env::remove_var("TEXTBIN_TOKEN") },
        }
        result.unwrap();
        assert_eq!(
            receiver.recv_timeout(Duration::from_secs(1)).unwrap(),
            "environment"
        );
        let _ = stop_server.send(());
        server.join().unwrap();
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    fn revoke_server(
        name: &'static str,
        sender: mpsc::Sender<&'static str>,
    ) -> (String, thread::JoinHandle<()>, mpsc::Sender<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (stop_sender, stop_receiver) = mpsc::channel();
        let server = thread::spawn(move || {
            let deadline = std::time::Instant::now() + Duration::from_secs(2);
            while std::time::Instant::now() < deadline {
                if stop_receiver.try_recv().is_ok() {
                    return;
                }

                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let mut request = [0; 2048];
                        let _ = stream.read(&mut request).unwrap();
                        sender.send(name).unwrap();
                        write!(
                            stream,
                            "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        )
                        .unwrap();
                        return;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => panic!("failed to accept request: {error}"),
                }
            }
        });
        (url, server, stop_sender)
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
            .join(format!("textbin-logout-{}-{nonce}", std::process::id()))
            .join("config.toml")
    }
}
