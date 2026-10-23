//! 应用内部host客户端接入保护；不改变host到设备daemon的官方协议。
//! 固定HDC banner不能证明本地客户端身份，因此在任何协议解析前校验进程私有随机码。
use std::io::{Error, ErrorKind};
use std::sync::OnceLock;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use rand::RngCore;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

static TOKEN: OnceLock<[u8; 32]> = OnceLock::new();

/// 随机码只保留在当前进程，不写日志、配置、状态或返回给ArkTS。
pub fn initialize() { TOKEN.get_or_init(|| { let mut key = [0u8; 32]; rand::rngs::OsRng.fill_bytes(&mut key); key }); }

/// 不发送秘密本身：同一随机challenge上的双向HMAC分别绑定客户端和服务器用途。
fn proof(key: &[u8; 32], purpose: &[u8], challenge: &[u8; 32]) -> Hmac<Sha256> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("fixed key length");
    mac.update(purpose); mac.update(challenge); mac
}

/// 认证阶段固定读取32字节并限制时长，无法把短帧/大帧带入原始协议解析。
async fn read(stream: &mut TcpStream, bytes: &mut [u8; 32]) -> std::io::Result<()> {
    tokio::time::timeout(std::time::Duration::from_secs(3), stream.read_exact(bytes))
        .await.map_err(|_| Error::new(ErrorKind::TimedOut, "private client admission timeout"))??;
    Ok(())
}

/// 受控库客户端先发私有前缀；前缀不进入设备协议或普通HDC命令正文。
pub async fn send(stream: &mut TcpStream) -> std::io::Result<()> {
    let token = TOKEN.get().ok_or_else(|| Error::new(ErrorKind::PermissionDenied, "host not initialized"))?;
    let mut challenge = [0u8; 32]; read(stream, &mut challenge).await?;
    let response = proof(token, b"AMCL-HDC-CLIENT", &challenge).finalize().into_bytes();
    stream.write_all(&response).await?;
    let mut server_proof = [0u8; 32]; read(stream, &mut server_proof).await?;
    proof(token, b"AMCL-HDC-SERVER", &challenge).verify_slice(&server_proof)
        .map_err(|_| Error::new(ErrorKind::PermissionDenied, "private server admission denied"))
}

/// 外部连接在3秒内必须提供完整前缀；逐字节常量时间比较后才进入原始HDC握手。
pub async fn accept(stream: &mut TcpStream) -> std::io::Result<()> {
    let token = TOKEN.get().ok_or_else(|| Error::new(ErrorKind::PermissionDenied, "host not initialized"))?;
    let mut challenge = [0u8; 32]; rand::rngs::OsRng.fill_bytes(&mut challenge);
    stream.write_all(&challenge).await?;
    let mut supplied = [0u8; 32]; read(stream, &mut supplied).await?;
    proof(token, b"AMCL-HDC-CLIENT", &challenge).verify_slice(&supplied)
        .map_err(|_| Error::new(ErrorKind::PermissionDenied, "private client admission denied"))?;
    let response = proof(token, b"AMCL-HDC-SERVER", &challenge).finalize().into_bytes();
    stream.write_all(&response).await
}
