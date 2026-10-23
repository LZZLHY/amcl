//! RSA authentication for HDC USB sessions.

use hdc_protocol::config::{HDC_HOST_DAEMON_BUF_SEPARATOR, RSA_PRIKEY_NAME, RSA_PRIKEY_PATH};
use rand::rngs::OsRng;
use rsa::pkcs1::{DecodeRsaPrivateKey, EncodeRsaPrivateKey};
use rsa::pkcs8::{DecodePublicKey, EncodePublicKey, LineEnding};
use base64::Engine;
use rsa::pkcs8::DecodePrivateKey;
use rsa::pss::SigningKey;
use rsa::signature::{RandomizedSigner, SignatureEncoding};
use sha2::Sha512;
use rsa::{RsaPrivateKey, RsaPublicKey};
use std::io::{self, Error, ErrorKind};
use std::path::PathBuf;

const RSA_KEY_BITS: usize = 3072;
static IDENTITY_ROOT: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

/// 应用内身份目录显式注入，不修改整个AMCL/JVM共享的HOME；同进程不能切换到其他目录。
pub fn set_identity_root(root: String) -> io::Result<()> {
    let path = PathBuf::from(root);
    if !path.is_absolute() { return Err(Error::new(ErrorKind::InvalidInput, "identity root must be absolute")); }
    if let Some(existing) = IDENTITY_ROOT.get() {
        return if existing == &path { Ok(()) } else { Err(Error::new(ErrorKind::PermissionDenied, "identity root already fixed")) };
    }
    IDENTITY_ROOT.set(path).map_err(|_| Error::new(ErrorKind::AlreadyExists, "identity root already initialized"))
}

fn get_user_key_dir() -> io::Result<PathBuf> {
    if let Some(root) = IDENTITY_ROOT.get() { return Ok(root.join(RSA_PRIKEY_PATH)); }
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .map_err(|_| Error::new(ErrorKind::NotFound, "cannot determine home directory"))?;
    Ok(PathBuf::from(home).join(RSA_PRIKEY_PATH))
}

pub fn get_private_key_path() -> io::Result<PathBuf> {
    Ok(get_user_key_dir()?.join(RSA_PRIKEY_NAME))
}

pub fn get_public_key_path() -> io::Result<PathBuf> {
    Ok(get_user_key_dir()?.join(format!("{}.pub", RSA_PRIKEY_NAME)))
}

fn get_hostname() -> String {
    #[cfg(windows)]
    {
        std::env::var("COMPUTERNAME").unwrap_or_else(|_| "unknown".to_string())
    }
    #[cfg(not(windows))]
    {
        unsafe {
            let mut buf = [0u8; 256];
            if libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) == 0 {
                let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
                String::from_utf8_lossy(&buf[..len]).to_string()
            } else {
                "unknown".to_string()
            }
        }
    }
}

fn generate_key_pair(
    pri_path: &std::path::Path,
    pub_path: &std::path::Path,
) -> io::Result<(RsaPrivateKey, RsaPublicKey)> {
    tracing::info!("Generating new RSA-{} key pair, this may take a few seconds...", RSA_KEY_BITS);
    let mut rng = OsRng;
    let private_key = RsaPrivateKey::new(&mut rng, RSA_KEY_BITS).map_err(|e| {
        Error::new(
            ErrorKind::Other,
            format!("RSA key generation failed: {e}"),
        )
    })?;
    let public_key = RsaPublicKey::from(&private_key);

    if let Some(parent) = pri_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let pri_pem = private_key.to_pkcs1_pem(LineEnding::LF).map_err(|e| {
        Error::new(
            ErrorKind::Other,
            format!("PEM encode private key failed: {e}"),
        )
    })?;
    std::fs::write(pri_path, pri_pem.as_bytes())?;
    // 私钥和目录即使处于应用沙箱仍收紧权限；公钥继续按上游格式生成。
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(pri_path, std::fs::Permissions::from_mode(0o600))?;
        if let Some(parent) = pri_path.parent() { std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?; }
    }

    let pub_pem = public_key.to_public_key_pem(LineEnding::LF).map_err(|e| {
        Error::new(
            ErrorKind::Other,
            format!("PEM encode public key failed: {e}"),
        )
    })?;
    std::fs::write(pub_path, pub_pem)?;
    tracing::info!("RSA key pair generated and saved to {}", pri_path.parent().unwrap_or(std::path::Path::new(".")).display());

    Ok((private_key, public_key))
}

pub fn load_or_generate_keys() -> io::Result<(RsaPrivateKey, RsaPublicKey)> {
    let pri_path = get_private_key_path()?;
    let pub_path = get_public_key_path()?;

    if pri_path.exists() && pub_path.exists() {
        let pri_pem = std::fs::read_to_string(&pri_path)?;
        let pub_pem = std::fs::read_to_string(&pub_path)?;

        let private_key = RsaPrivateKey::from_pkcs1_pem(&pri_pem)
            .or_else(|_| RsaPrivateKey::from_pkcs8_pem(&pri_pem))
            .map_err(|e| {
                Error::new(
                    ErrorKind::InvalidData,
                    format!("Failed to load private key: {e}"),
                )
            })?;

        let public_key = RsaPublicKey::from_public_key_pem(&pub_pem).map_err(|e| {
            Error::new(
                ErrorKind::InvalidData,
                format!("Failed to load public key: {e}"),
            )
        })?;

        Ok((private_key, public_key))
    } else {
        generate_key_pair(&pri_path, &pub_path)
    }
}

/// Get public key info string: `hostname<0x0C>pubkey_pem`
pub fn get_public_key_info() -> io::Result<String> {
    let (_, public_key) = load_or_generate_keys()?;
    let pub_pem = public_key.to_public_key_pem(LineEnding::LF).map_err(|e| {
        Error::new(
            ErrorKind::Other,
            format!("PEM encode public key failed: {e}"),
        )
    })?;
    let hostname = get_hostname();
    Ok(format!(
        "{}{}{}",
        hostname, HDC_HOST_DAEMON_BUF_SEPARATOR, pub_pem
    ))
}

/// Sign challenge with RSA-PSS + SHA512, return base64-encoded signature.
pub fn rsa_sign_challenge(challenge: &str) -> io::Result<String> {
    let (private_key, _) = load_or_generate_keys()?;
    let signing_key = SigningKey::<Sha512>::new(private_key);
    let mut rng = OsRng;
    let signature = signing_key.sign_with_rng(&mut rng, challenge.as_bytes());
    Ok(base64::engine::general_purpose::STANDARD.encode(signature.to_bytes().as_ref()))
}

/// Decrypt the daemon-provided PSK using the host RSA private key (OAEP SHA-256).
pub fn decrypt_psk(encrypted: &[u8]) -> io::Result<Vec<u8>> {
    let (private_key, _) = load_or_generate_keys()?;
    let padding = rsa::Oaep::new_with_mgf_hash::<sha2::Sha256, sha2::Sha256>();
    private_key
        .decrypt(padding, encrypted)
        .map_err(|e| Error::new(ErrorKind::InvalidData, format!("RSA decrypt PSK failed: {e}")))
}
