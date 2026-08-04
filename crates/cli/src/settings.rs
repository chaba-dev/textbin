use anyhow::{Context, Result};
use directories::ProjectDirs;
use keyring::{Entry, Error as KeyringError};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use textbin_client::{Client, Identity};

const DEFAULT_TEXTBIN_URL: &str = "http://localhost:4400";
const DEFAULT_PROFILE: &str = "default";
const KEYRING_SERVICE: &str = "com.textbin.cli";

#[derive(Debug, Default, Deserialize, Serialize)]
struct Config {
    active_profile: Option<String>,
    #[serde(default)]
    profiles: BTreeMap<String, Profile>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Profile {
    pub url: String,
    pub credential: Option<String>,
    pub user_id: Option<String>,
    pub email: Option<String>,
}

pub struct Settings {
    path: PathBuf,
}

impl Settings {
    pub fn new(path: Option<PathBuf>) -> Result<Self> {
        let path = match path {
            Some(path) => path,
            None => ProjectDirs::from("com", "Textbin", "Textbin")
                .context("could not determine the platform configuration directory")?
                .config_dir()
                .join("config.toml"),
        };

        Ok(Self { path })
    }

    pub fn client(&self) -> Result<Client> {
        let config = self.load()?;
        let profile = active_profile(&config);
        let environment_url = std::env::var("TEXTBIN_URL").ok();
        let environment_token = environment_token();
        let url = environment_url
            .as_deref()
            .or_else(|| profile.map(|profile| profile.url.as_str()))
            .unwrap_or(DEFAULT_TEXTBIN_URL);

        let token = match environment_token {
            Some(token) => Some(token),
            _ if environment_url.is_some() => None,
            _ => profile.map(load_profile_token).transpose()?.flatten(),
        };

        Ok(Client::try_new(url)?.with_api_token(token))
    }

    pub fn server_client(&self) -> Result<Client> {
        let config = self.load()?;
        let profile = active_profile(&config);
        let url = std::env::var("TEXTBIN_URL")
            .ok()
            .or_else(|| profile.map(|profile| profile.url.clone()))
            .unwrap_or_else(|| DEFAULT_TEXTBIN_URL.to_string());

        Ok(Client::try_new(url)?)
    }

    pub fn active_profile_name(&self) -> Result<String> {
        Ok(self
            .load()?
            .active_profile
            .unwrap_or_else(|| DEFAULT_PROFILE.to_string()))
    }

    pub fn validate_profile_name<'a>(&self, name: &'a str) -> Result<&'a str> {
        let valid = !name.is_empty()
            && name.len() <= 64
            && name.bytes().all(|character| {
                character.is_ascii_alphanumeric() || matches!(character, b'-' | b'_')
            });

        if valid { Ok(name) } else { bail_profile_name() }
    }

    pub fn profile(&self, name: &str) -> Result<Option<Profile>> {
        Ok(self.load()?.profiles.get(name).cloned())
    }

    pub fn stored_client(&self, name: &str) -> Result<Option<Client>> {
        let Some(profile) = self.profile(name)? else {
            return Ok(None);
        };
        let Some(token) = load_profile_token(&profile)? else {
            return Ok(None);
        };

        Ok(Some(
            Client::try_new(profile.url)?.with_api_token(Some(token)),
        ))
    }

    pub fn save_login(
        &self,
        profile_name: &str,
        url: &str,
        identity: &Identity,
        token: &str,
    ) -> Result<()> {
        let client = Client::try_new(url)?;
        let credential = credential_name(profile_name, client.base_url());
        let entry = keyring_entry(&credential)?;

        entry
            .set_password(token)
            .context("could not store the API token in the OS credential store")?;

        let mut config = self.load()?;
        config.active_profile = Some(profile_name.to_string());
        config.profiles.insert(
            profile_name.to_string(),
            Profile {
                url: client.base_url().to_string(),
                credential: Some(credential.clone()),
                user_id: Some(identity.user.id.clone()),
                email: Some(identity.user.email.clone()),
            },
        );

        if let Err(error) = self.save(&config) {
            let _ = entry.delete_credential();
            return Err(error);
        }

        Ok(())
    }

    pub fn forget_login(&self, profile_name: &str) -> Result<bool> {
        let mut config = self.load()?;
        let Some(profile) = config.profiles.get_mut(profile_name) else {
            return Ok(false);
        };

        let had_credential = profile.credential.is_some();

        if let Some(credential) = profile.credential.take() {
            delete_credential(&credential)?;
        }

        let had_login =
            had_credential || profile.user_id.take().is_some() || profile.email.take().is_some();
        self.save(&config)?;
        Ok(had_login)
    }

    pub fn default_server_url(&self, profile_name: &str) -> Result<String> {
        if let Ok(url) = std::env::var("TEXTBIN_URL") {
            return Ok(Client::try_new(url)?.base_url().to_string());
        }

        Ok(self
            .profile(profile_name)?
            .map(|profile| profile.url)
            .unwrap_or_else(|| DEFAULT_TEXTBIN_URL.to_string()))
    }

    fn load(&self) -> Result<Config> {
        match fs::read_to_string(&self.path) {
            Ok(contents) => toml::from_str(&contents)
                .with_context(|| format!("could not parse {}", self.path.display())),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Config::default()),
            Err(error) => {
                Err(error).with_context(|| format!("could not read {}", self.path.display()))
            }
        }
    }

    fn save(&self, config: &Config) -> Result<()> {
        let parent = self
            .path
            .parent()
            .context("configuration path must have a parent directory")?;
        fs::create_dir_all(parent)
            .with_context(|| format!("could not create {}", parent.display()))?;

        let contents = toml::to_string_pretty(config).context("could not encode CLI settings")?;
        let temporary_path = temporary_path(&self.path);
        write_private_file(&temporary_path, contents.as_bytes())?;

        #[cfg(windows)]
        if self.path.exists() {
            fs::remove_file(&self.path)
                .with_context(|| format!("could not replace {}", self.path.display()))?;
        }

        fs::rename(&temporary_path, &self.path)
            .with_context(|| format!("could not replace {}", self.path.display()))
    }
}

pub fn environment_token() -> Option<String> {
    std::env::var("TEXTBIN_TOKEN")
        .ok()
        .filter(|token| !token.is_empty())
}

fn active_profile(config: &Config) -> Option<&Profile> {
    config
        .active_profile
        .as_ref()
        .and_then(|name| config.profiles.get(name))
}

fn credential_name(profile_name: &str, url: &str) -> String {
    format!("{profile_name}:{url}")
}

fn keyring_entry(credential: &str) -> Result<Entry> {
    Entry::new(KEYRING_SERVICE, credential).context(
        "could not access the OS credential store; use TEXTBIN_TOKEN for headless sessions",
    )
}

fn load_profile_token(profile: &Profile) -> Result<Option<String>> {
    let Some(credential) = profile.credential.as_deref() else {
        return Ok(None);
    };
    let entry = keyring_entry(credential)?;

    match entry.get_password() {
        Ok(token) => Ok(Some(token)),
        Err(KeyringError::NoEntry) => Ok(None),
        Err(error) => {
            Err(error).context("could not read the API token from the OS credential store")
        }
    }
}

fn delete_credential(credential: &str) -> Result<()> {
    let entry = keyring_entry(credential)?;

    match entry.delete_credential() {
        Ok(()) | Err(KeyringError::NoEntry) => Ok(()),
        Err(error) => {
            Err(error).context("could not delete the API token from the OS credential store")
        }
    }
}

fn temporary_path(path: &Path) -> PathBuf {
    let mut file_name = path
        .file_name()
        .map(|name| name.to_os_string())
        .unwrap_or_default();
    file_name.push(".tmp");
    path.with_file_name(file_name)
}

fn write_private_file(path: &Path, contents: &[u8]) -> Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);

    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }

    let mut file = options
        .open(path)
        .with_context(|| format!("could not write {}", path.display()))?;
    file.write_all(contents)
        .with_context(|| format!("could not write {}", path.display()))?;
    file.sync_all()
        .with_context(|| format!("could not flush {}", path.display()))
}

fn bail_profile_name<T>() -> Result<T> {
    anyhow::bail!(
        "profile names may contain only letters, numbers, '-' and '_' (maximum 64 characters)"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn config_round_trip_preserves_profiles_without_secrets() {
        let path = temp_config_path();
        let settings = Settings::new(Some(path.clone())).unwrap();
        let config = Config {
            active_profile: Some("demo".to_string()),
            profiles: BTreeMap::from([(
                "demo".to_string(),
                Profile {
                    url: "https://demo.textbin.com".to_string(),
                    credential: Some("demo:https://demo.textbin.com".to_string()),
                    user_id: Some("user-id".to_string()),
                    email: Some("user@example.com".to_string()),
                },
            )]),
        };

        settings.save(&config).unwrap();
        let loaded = settings.load().unwrap();

        assert_eq!(loaded.active_profile.as_deref(), Some("demo"));
        assert_eq!(
            loaded.profiles["demo"].email.as_deref(),
            Some("user@example.com")
        );
        let contents = fs::read_to_string(&path).unwrap();
        assert!(!contents.contains("txb_"));

        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn validates_profile_names() {
        let settings = Settings::new(Some(temp_config_path())).unwrap();

        assert_eq!(settings.validate_profile_name("demo_1").unwrap(), "demo_1");
        assert!(settings.validate_profile_name("").is_err());
        assert!(settings.validate_profile_name("not valid").is_err());
        assert!(settings.validate_profile_name(&"x".repeat(65)).is_err());
    }

    fn temp_config_path() -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();

        std::env::temp_dir()
            .join(format!("textbin-settings-{}-{nonce}", std::process::id()))
            .join("config.toml")
    }
}
