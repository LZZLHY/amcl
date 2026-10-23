//! 本机候选端口的无权限握手探测。只发协议介绍，不发送公钥、签名、命令或申请系统信任。
use hdc_protocol::config::{get_version, AuthType, HdcCommand, TaskMessage, HANDSHAKE_MESSAGE};
use hdc_protocol::serializer::{concat_pack, unpack_payload_head, unpack_payload_protect,
    HdcDeserialize, HdcSerialize, SessionHandShake, HEAD_SIZE};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use std::time::Duration;

/// C++ 已将候选限制为本机端口；此函数再次固定 loopback，并限制读帧大小、时间和生命周期。
#[no_mangle]
pub extern "C" fn amcl_hdc_core_probe_port(port: i32) -> i32 {
    if !(1..=65535).contains(&port) { return 0; }
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(value) => value, Err(_) => return 0,
    };
    runtime.block_on(async {
        match tokio::time::timeout(Duration::from_millis(600), probe(port as u16)).await {
            Ok(Ok(true)) => 1, _ => 0,
        }
    })
}

async fn probe(port: u16) -> std::io::Result<bool> {
    let mut stream = tokio::net::TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port)).await?;
    let hello = SessionHandShake {
        banner: HANDSHAKE_MESSAGE.to_owned(), auth_type: AuthType::None as u8,
        session_id: rand::random(), connect_key: format!("127.0.0.1:{port}"),
        buf: String::new(), version: format!("{}47d583e40754ffe6", get_version()),
    };
    stream.write_all(&concat_pack(&TaskMessage { channel_id: 0, command: HdcCommand::KernelHandshake,
        payload: hello.serialize() })).await?;
    let mut header = [0u8; HEAD_SIZE]; stream.read_exact(&mut header).await?;
    let head = unpack_payload_head(&header)?;
    // 未知本机服务的响应不能决定任意内存分配。正式帧校验继续复用锁定的上游编解码器。
    if head.head_size == 0 || head.head_size > 128 || head.data_size == 0 || head.data_size > 4096 { return Ok(false); }
    let mut protect = vec![0u8; head.head_size as usize]; stream.read_exact(&mut protect).await?;
    let guard = unpack_payload_protect(&protect)?;
    if guard.command_flag != HdcCommand::KernelHandshake as u32 || guard.channel_id != 0 { return Ok(false); }
    let mut payload = vec![0u8; head.data_size as usize]; stream.read_exact(&mut payload).await?;
    let reply = SessionHandShake::deserialize(&payload)?;
    Ok(reply.banner == HANDSHAKE_MESSAGE)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    /// 真实 TCP 边界上验证已锁定编解码器，不用通用“端口开放”替代 HDC 协议身份。
    fn serve(reply: Vec<u8>) -> i32 {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
            let mut request = [0u8; 1024]; assert!(stream.read(&mut request).unwrap() > 0);
            stream.write_all(&reply).unwrap();
        });
        let result = amcl_hdc_core_probe_port(port as i32); server.join().unwrap(); result
    }
    #[test]
    fn genuine_handshake_and_unrelated_services() {
        let response = SessionHandShake { banner: HANDSHAKE_MESSAGE.to_owned(), auth_type: AuthType::Publickey as u8,
            session_id: 1, connect_key: String::new(), buf: String::new(), version: get_version() };
        assert_eq!(serve(concat_pack(&TaskMessage { channel_id: 0, command: HdcCommand::KernelHandshake, payload: response.serialize() })), 1);
        assert_eq!(serve(b"HTTP/1.1 400 Bad Request\r\n\r\n".to_vec()), 0);
        let oversized = hdc_protocol::serializer::PayloadHead { flag: *b"HW", reserve: [0;2], protocol_ver: 1, head_size: 16, data_size: 0xffff_ffff };
        assert_eq!(serve(oversized.serialize()), 0);
        assert_eq!(amcl_hdc_core_probe_port(0), 0);
        assert_eq!(amcl_hdc_core_probe_port(65536), 0);
    }
}
