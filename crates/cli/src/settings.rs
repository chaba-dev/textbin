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

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct Config {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    config_id: Option<String>,
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
        let environment_url = std::env::var("TEXTBIN_URL").ok();
        let environment_token = environment_token();

        if let (Some(url), Some(token)) = (&environment_url, &environment_token) {
            return Ok(Client::try_new(url)?.with_api_token(Some(token.clone())));
        }

        let config = self.load()?;
        let profile = active_profile(&config);
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
        if let Ok(url) = std::env::var("TEXTBIN_URL") {
            return Client::try_new(url).map_err(Into::into);
        }

        let config = self.load()?;
        let profile = active_profile(&config);
        let url = profile
            .map(|profile| profile.url.clone())
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

    pub fn activate_profile(&self, name: &str) -> Result<()> {
        let mut config = self.load()?;
        config.active_profile = Some(name.to_string());
        self.save(&config)
    }

    pub fn save_environment_login(
        &self,
        profile_name: &str,
        url: &str,
        identity: &Identity,
    ) -> Result<()> {
        let client = Client::try_new(url)?;
        let mut config = self.load()?;
        if config
            .profiles
            .get(profile_name)
            .is_some_and(|profile| profile.url == client.base_url() && profile.credential.is_some())
        {
            config.active_profile = Some(profile_name.to_string());
            return self.save(&config);
        }

        let previous_credential = config
            .profiles
            .get(profile_name)
            .filter(|profile| profile.url != client.base_url())
            .and_then(|profile| profile.credential.clone());
        let credential = config
            .profiles
            .get(profile_name)
            .filter(|profile| profile.url == client.base_url())
            .and_then(|profile| profile.credential.clone());

        config.active_profile = Some(profile_name.to_string());
        config.profiles.insert(
            profile_name.to_string(),
            Profile {
                url: client.base_url().to_string(),
                credential,
                user_id: Some(identity.user.id.clone()),
                email: Some(identity.user.email.clone()),
            },
        );
        self.save(&config)?;

        if let Some(previous_credential) = previous_credential {
            let _ = delete_credential(&previous_credential);
        }

        Ok(())
    }

    pub fn migrate_login(&self, profile_name: &str, identity: &Identity) -> Result<()> {
        let config = self.load()?;
        let Some(profile) = config.profiles.get(profile_name) else {
            return Ok(());
        };
        let Some(credential) = profile.credential.as_deref() else {
            return Ok(());
        };
        let namespaced = config
            .config_id
            .as_deref()
            .is_some_and(|config_id| credential.starts_with(&format!("{config_id}:")));

        if namespaced {
            return Ok(());
        }

        let Some(token) = load_profile_token(profile)? else {
            return Ok(());
        };
        self.save_login(profile_name, &profile.url, identity, &token)
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
        let mut config = self.load()?;
        let previous_config_id = config.config_id.clone();
        let config_id = config
            .config_id
            .get_or_insert_with(|| uuid::Uuid::new_v4().to_string())
            .clone();
        let credential = credential_name(&config_id, profile_name, client.base_url());
        let previous_credential = config
            .profiles
            .get(profile_name)
            .and_then(|profile| profile.credential.clone());
        let entry = keyring_entry(&credential)?;
        let previous_token = if previous_credential.as_deref() == Some(credential.as_str()) {
            load_entry_token(&entry)?
        } else {
            None
        };

        entry
            .set_password(token)
            .context("could not store the API token in the OS credential store")?;

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
            let rollback = match previous_token {
                Some(previous_token) => entry.set_password(&previous_token),
                None => match entry.delete_credential() {
                    Ok(()) | Err(KeyringError::NoEntry) => Ok(()),
                    Err(error) => Err(error),
                },
            };

            return match rollback {
                Ok(()) => Err(error),
                Err(rollback_error) => Err(error.context(format!(
                    "could not restore the previous API token after the configuration save failed: {rollback_error}"
                ))),
            };
        }

        if let Some(previous_credential) = previous_credential
            && previous_credential != credential
            && previous_config_id
                .as_deref()
                .is_some_and(|config_id| previous_credential.starts_with(&format!("{config_id}:")))
        {
            let _ = delete_credential(&previous_credential);
        }

        Ok(())
    }

    pub fn forget_login(&self, profile_name: &str) -> Result<bool> {
        let mut config = self.load()?;
        let previous_config = config.clone();
        let Some(profile) = config.profiles.get_mut(profile_name) else {
            return Ok(false);
        };

        let had_credential = profile.credential.is_some();

        let credential = profile.credential.take();

        let had_login =
            had_credential || profile.user_id.take().is_some() || profile.email.take().is_some();
        self.save(&config)?;

        if let Some(credential) = credential
            && let Err(error) = delete_credential(&credential)
        {
            return match self.save(&previous_config) {
                Ok(()) => Err(error),
                Err(rollback_error) => Err(error.context(format!(
                    "could not restore the login after credential deletion failed: {rollback_error}"
                ))),
            };
        }

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

fn credential_name(config_id: &str, profile_name: &str, url: &str) -> String {
    format!("{config_id}:{profile_name}:{url}")
}

fn keyring_entry(credential: &str) -> Result<Entry> {
    #[cfg(test)]
    return Ok(Entry {
        inner: keyring_core::Entry::new(KEYRING_SERVICE, credential)
            .context("could not access the mock OS credential store")?,
    });

    #[cfg(not(test))]
    Entry::new(KEYRING_SERVICE, credential).context(
        "could not access the OS credential store; use TEXTBIN_TOKEN for headless sessions",
    )
}

#[cfg(test)]
pub(crate) fn initialize_mock_keyring() {
    use std::sync::Once;

    static INITIALIZE: Once = Once::new();
    INITIALIZE.call_once(|| {
        keyring_core::set_default_store(keyring_core::mock::Store::new().unwrap());
    });
}

#[cfg(test)]
pub(crate) static TEST_ENVIRONMENT: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn load_profile_token(profile: &Profile) -> Result<Option<String>> {
    let Some(credential) = profile.credential.as_deref() else {
        return Ok(None);
    };
    let entry = keyring_entry(credential)?;

    load_entry_token(&entry)
}

fn load_entry_token(entry: &Entry) -> Result<Option<String>> {
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
            config_id: Some("config-id".to_string()),
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

    #[test]
    fn replacing_a_profiles_server_deletes_the_superseded_credential() {
        let _environment = TEST_ENVIRONMENT.lock().unwrap();
        initialize_mock_keyring();
        let path = temp_config_path();
        let settings = Settings::new(Some(path.clone())).unwrap();
        let identity = test_identity();
        let old_url = "https://old.example.com";
        let new_url = "https://new.example.com";

        settings
            .save_login("demo", old_url, &identity, "old-token")
            .unwrap();
        let old_credential_name = settings
            .profile("demo")
            .unwrap()
            .unwrap()
            .credential
            .unwrap();
        settings
            .save_login("demo", new_url, &identity, "new-token")
            .unwrap();

        let old_credential = keyring_entry(&old_credential_name).unwrap();
        assert!(matches!(
            old_credential.get_password(),
            Err(KeyringError::NoEntry)
        ));

        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn replacing_a_profiles_server_succeeds_when_old_credential_cleanup_fails() {
        let _environment = TEST_ENVIRONMENT.lock().unwrap();
        initialize_mock_keyring();
        let path = temp_config_path();
        let settings = Settings::new(Some(path.clone())).unwrap();
        let identity = test_identity();
        let old_url = "https://cleanup-error-old.example.com";
        let new_url = "https://cleanup-error-new.example.com";

        settings
            .save_login("cleanup_error", old_url, &identity, "old-token")
            .unwrap();
        let old_credential_name = settings
            .profile("cleanup_error")
            .unwrap()
            .unwrap()
            .credential
            .unwrap();
        let old_credential = keyring_entry(&old_credential_name).unwrap();
        let mock = old_credential
            .inner
            .as_any()
            .downcast_ref::<keyring_core::mock::Cred>()
            .unwrap();
        mock.set_error(KeyringError::Invalid(
            "test cleanup error".to_string(),
            "credential".to_string(),
        ));

        settings
            .save_login("cleanup_error", new_url, &identity, "new-token")
            .unwrap();

        let profile = settings.profile("cleanup_error").unwrap().unwrap();
        assert_eq!(profile.url, new_url);
        assert_eq!(
            load_profile_token(&profile).unwrap().as_deref(),
            Some("new-token")
        );
        assert_eq!(old_credential.get_password().unwrap(), "old-token");

        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn failed_config_commit_restores_the_existing_token() {
        let _environment = TEST_ENVIRONMENT.lock().unwrap();
        initialize_mock_keyring();
        let path = temp_config_path();
        let settings = Settings::new(Some(path.clone())).unwrap();
        let identity = test_identity();
        let url = "https://rollback.example.com";

        settings
            .save_login("rollback", url, &identity, "old-token")
            .unwrap();
        fs::create_dir(temporary_path(&path)).unwrap();

        let result = settings.save_login("rollback", url, &identity, "new-token");

        assert!(result.is_err());
        let profile = settings.profile("rollback").unwrap().unwrap();
        assert_eq!(
            load_profile_token(&profile).unwrap().as_deref(),
            Some("old-token")
        );

        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn separate_config_files_do_not_share_keyring_credentials() {
        let _environment = TEST_ENVIRONMENT.lock().unwrap();
        initialize_mock_keyring();
        let first_path = temp_config_path();
        let second_path = temp_config_path();
        let first = Settings::new(Some(first_path.clone())).unwrap();
        let second = Settings::new(Some(second_path.clone())).unwrap();
        let identity = test_identity();
        let url = "https://shared.example.com";

        first
            .save_login("default", url, &identity, "first-token")
            .unwrap();
        second
            .save_login("default", url, &identity, "second-token")
            .unwrap();

        let first_profile = first.profile("default").unwrap().unwrap();
        let second_profile = second.profile("default").unwrap().unwrap();
        assert_eq!(
            load_profile_token(&first_profile).unwrap().as_deref(),
            Some("first-token")
        );
        assert_eq!(
            load_profile_token(&second_profile).unwrap().as_deref(),
            Some("second-token")
        );

        fs::remove_dir_all(first_path.parent().unwrap()).unwrap();
        fs::remove_dir_all(second_path.parent().unwrap()).unwrap();
    }

    #[test]
    fn environment_client_ignores_malformed_config_when_fully_configured() {
        let _environment = TEST_ENVIRONMENT.lock().unwrap();
        let old_url = std::env::var_os("TEXTBIN_URL");
        let old_token = std::env::var_os("TEXTBIN_TOKEN");
        let path = temp_config_path();
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "not valid toml = [").unwrap();
        unsafe {
            std::env::set_var("TEXTBIN_URL", "https://environment.example.com");
            std::env::set_var("TEXTBIN_TOKEN", "environment-token");
        }

        let result = Settings::new(Some(path.clone())).unwrap().client();

        restore_environment("TEXTBIN_URL", old_url);
        restore_environment("TEXTBIN_TOKEN", old_token);
        let client = result.unwrap();
        assert_eq!(client.base_url(), "https://environment.example.com");
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn failed_config_commit_does_not_forget_existing_token() {
        let _environment = TEST_ENVIRONMENT.lock().unwrap();
        initialize_mock_keyring();
        let path = temp_config_path();
        let settings = Settings::new(Some(path.clone())).unwrap();
        let identity = test_identity();

        settings
            .save_login("default", "https://example.com", &identity, "stored-token")
            .unwrap();
        fs::create_dir(temporary_path(&path)).unwrap();

        assert!(settings.forget_login("default").is_err());
        let profile = settings.profile("default").unwrap().unwrap();
        assert_eq!(
            load_profile_token(&profile).unwrap().as_deref(),
            Some("stored-token")
        );

        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn legacy_credential_migration_does_not_log_out_other_configs() {
        let _environment = TEST_ENVIRONMENT.lock().unwrap();
        initialize_mock_keyring();
        let first_path = temp_config_path();
        let second_path = temp_config_path();
        let first = Settings::new(Some(first_path.clone())).unwrap();
        let second = Settings::new(Some(second_path.clone())).unwrap();
        let legacy_credential = "default:https://legacy.example.com";
        keyring_entry(legacy_credential)
            .unwrap()
            .set_password("legacy-token")
            .unwrap();
        let legacy_config = Config {
            config_id: None,
            active_profile: Some("default".to_string()),
            profiles: BTreeMap::from([(
                "default".to_string(),
                Profile {
                    url: "https://legacy.example.com".to_string(),
                    credential: Some(legacy_credential.to_string()),
                    user_id: Some("user-id".to_string()),
                    email: Some("user@example.com".to_string()),
                },
            )]),
        };
        first.save(&legacy_config).unwrap();
        second.save(&legacy_config).unwrap();

        first.migrate_login("default", &test_identity()).unwrap();

        let first_profile = first.profile("default").unwrap().unwrap();
        let second_profile = second.profile("default").unwrap().unwrap();
        assert_ne!(first_profile.credential, second_profile.credential);
        assert_eq!(
            load_profile_token(&first_profile).unwrap().as_deref(),
            Some("legacy-token")
        );
        assert_eq!(
            load_profile_token(&second_profile).unwrap().as_deref(),
            Some("legacy-token")
        );

        fs::remove_dir_all(first_path.parent().unwrap()).unwrap();
        fs::remove_dir_all(second_path.parent().unwrap()).unwrap();
    }

    #[test]
    fn environment_login_does_not_relabel_a_stored_credential() {
        let _environment = TEST_ENVIRONMENT.lock().unwrap();
        initialize_mock_keyring();
        let path = temp_config_path();
        let settings = Settings::new(Some(path.clone())).unwrap();
        let url = "https://example.com";
        settings
            .save_login("default", url, &test_identity(), "stored-token")
            .unwrap();
        let mut environment_identity = test_identity();
        environment_identity.user.id = "other-user-id".to_string();
        environment_identity.user.email = "other@example.com".to_string();

        settings
            .save_environment_login("default", url, &environment_identity)
            .unwrap();

        let profile = settings.profile("default").unwrap().unwrap();
        assert_eq!(profile.user_id.as_deref(), Some("user-id"));
        assert_eq!(profile.email.as_deref(), Some("user@example.com"));
        assert_eq!(
            load_profile_token(&profile).unwrap().as_deref(),
            Some("stored-token")
        );
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn failed_credential_deletion_restores_the_profile() {
        let _environment = TEST_ENVIRONMENT.lock().unwrap();
        initialize_mock_keyring();
        let path = temp_config_path();
        let settings = Settings::new(Some(path.clone())).unwrap();
        settings
            .save_login(
                "default",
                "https://example.com",
                &test_identity(),
                "stored-token",
            )
            .unwrap();
        let profile = settings.profile("default").unwrap().unwrap();
        let entry = keyring_entry(profile.credential.as_deref().unwrap()).unwrap();
        entry
            .inner
            .as_any()
            .downcast_ref::<keyring_core::mock::Cred>()
            .unwrap()
            .set_error(KeyringError::Invalid(
                "test deletion error".to_string(),
                "credential".to_string(),
            ));

        assert!(settings.forget_login("default").is_err());

        let profile = settings.profile("default").unwrap().unwrap();
        assert_eq!(
            load_profile_token(&profile).unwrap().as_deref(),
            Some("stored-token")
        );
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    fn restore_environment(name: &str, value: Option<std::ffi::OsString>) {
        match value {
            Some(value) => unsafe { std::env::set_var(name, value) },
            None => unsafe { std::env::remove_var(name) },
        }
    }

    fn test_identity() -> Identity {
        Identity {
            user: textbin_client::AuthenticatedUser {
                id: "user-id".to_string(),
                email: "user@example.com".to_string(),
            },
            token: textbin_client::ApiTokenMetadata {
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
            .join(format!("textbin-settings-{}-{nonce}", std::process::id()))
            .join("config.toml")
    }
}
