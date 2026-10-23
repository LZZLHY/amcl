//! HDC host server mode.

use base64::Engine;
use hdc_protocol::config::{HdcCommand, TaskMessage, HANDSHAKE_MESSAGE, BANNER_SIZE, KEY_MAX_SIZE, ConnectType, ConnStatus, get_version, MAX_SIZE_IOBUF, AuthType, HEARTBEAT_INTERVAL, ENV_SERVER_HEARTBEAT, ENV_ENCRYPT_CHANNEL, AUTH_TYPE_SSL_TLS_PSK, FEATURE_ENCRYPT_TCP, FEATURE_HEARTBEAT, HDC_HOST_DAEMON_BUF_SEPARATOR, MessageLevel};
use hdc_protocol::encrypt::PskCipher;
use hdc_protocol::serializer::{concat_pack, TransferConfig, TransferPayload, HdcDeserialize, HdcSerialize, SessionHandShake};
use std::collections::HashMap;
use std::io::{self, Error, ErrorKind};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use zip::ZipArchive;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, RwLock};
use tracing::{debug, error, info, trace, warn};

static FORWARD_LISTEN_IP: OnceLock<String> = OnceLock::new();
// 手机应用的 TCP 自连接无需枚举自身 USB。真机已证明普通应用无法初始化 libusb
// 全局上下文，上游枚举线程会因此 panic。这里仅选择运行时发现方式，保留全部 USB
// 传输实现及完整 HDC 命令；桌面调用默认仍启用 USB 发现。
static USB_DISCOVERY_ENABLED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);

/// 必须在启动 host 前设置；用于选择当前宿主实际可用的传输发现机制。
pub fn set_usb_discovery_enabled(enabled: bool) {
    USB_DISCOVERY_ENABLED.store(enabled, std::sync::atomic::Ordering::Relaxed);
}

pub fn set_forward_listen_ip(ip: String) {
    let _ = FORWARD_LISTEN_IP.set(ip);
}

fn get_forward_listen_ip() -> &'static str {
    FORWARD_LISTEN_IP.get().map(|s| s.as_str()).unwrap_or("127.0.0.1")
}

// ============================================================================
// ConnectMap - manages connected devices
// ============================================================================

#[derive(Debug, Clone)]
pub struct DaemonInfo {
    pub session_id: u32,
    pub conn_type: ConnectType,
    pub conn_status: ConnStatus,
    pub dev_name: String,
    pub version: String,
}

#[derive(Default)]
struct ConnectMapInner {
    map: HashMap<String, DaemonInfo>,
}

#[derive(Clone)]
pub struct ConnectMap {
    inner: Arc<RwLock<ConnectMapInner>>,
}

impl ConnectMap {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(RwLock::new(ConnectMapInner::default())),
        }
    }

    pub async fn put(&self, connect_key: String, info: DaemonInfo) {
        let mut guard = self.inner.write().await;
        guard.map.insert(connect_key, info);
    }

    pub async fn remove(&self, connect_key: &str) {
        let mut guard = self.inner.write().await;
        guard.map.remove(connect_key);
    }

    pub async fn contains_key(&self, connect_key: &str) -> bool {
        let guard = self.inner.read().await;
        guard.map.contains_key(connect_key)
    }

    pub async fn update_status(&self, connect_key: &str, status: ConnStatus) {
        let mut guard = self.inner.write().await;
        if let Some(info) = guard.map.get_mut(connect_key) {
            info.conn_status = status;
        }
    }

    pub async fn get_session_id(&self, connect_key: &str) -> Option<u32> {
        let guard = self.inner.read().await;
        if connect_key == "any" {
            // Auto-select: prefer Connected device
            for (_, info) in guard.map.iter() {
                if info.conn_status == ConnStatus::Connected {
                    return Some(info.session_id);
                }
            }
            // Fallback: if only one device total, return it
            if guard.map.len() == 1 {
                return guard.map.values().next().map(|info| info.session_id);
            }
            None
        } else {
            guard.map.get(connect_key).map(|info| info.session_id)
        }
    }

    pub async fn get_connect_key(&self, session_id: u32) -> Option<String> {
        let guard = self.inner.read().await;
        for (key, info) in guard.map.iter() {
            if info.session_id == session_id {
                return Some(key.clone());
            }
        }
        None
    }

    pub async fn get_list(&self, is_full: bool) -> Vec<String> {
        let guard = self.inner.read().await;
        let mut list = Vec::new();
        for (key, info) in guard.map.iter() {
            if !is_full {
                // list targets (non-verbose): only show connected devices
                if info.conn_status == ConnStatus::Connected {
                    list.push(key.clone());
                }
            } else {
                // list targets -v (verbose): show all devices with details
                let conn_type = match info.conn_type {
                    ConnectType::Tcp => "TCP",
                    ConnectType::Usb(_) => "USB",
                    ConnectType::Uart => "UART",
                    ConnectType::Bt => "BT",
                    ConnectType::HostUsb(_) => "HOSTUSB",
                    ConnectType::Bridge => "BRIDGE",
                };
                let status_str = match info.conn_status {
                    ConnStatus::Ready => "Ready",
                    ConnStatus::Connected => "Connected",
                    ConnStatus::Offline => "Offline",
                    ConnStatus::Unauthorized => "Unauthorized",
                };
                let dev_name = if info.dev_name.is_empty() {
                    "unknown..."
                } else {
                    &info.dev_name
                };
                // Official format: two tabs between key and connType
                list.push(format!("{}\t\t{}\t{}\t{}", key, conn_type, status_str, dev_name));
            }
        }
        list
    }

    pub async fn get_first_connected_key(&self) -> Option<String> {
        let guard = self.inner.read().await;
        for (key, info) in guard.map.iter() {
            if info.conn_status == ConnStatus::Connected {
                return Some(key.clone());
            }
        }
        None
    }
}

async fn resolve_connect_key(connect_map: &ConnectMap, connect_key: &str) -> io::Result<String> {
    if connect_key == "any" {
        // Use verbose list so entries include status; non-verbose list only returns keys.
        let list = connect_map.get_list(true).await;
        let connected: Vec<String> = list.into_iter().filter(|s| s.contains("Connected")).collect();
        if connected.is_empty() {
            Err(Error::new(ErrorKind::NotFound, "No device connected"))
        } else if connected.len() == 1 {
            // Extract key from formatted string: "<key>\t\t<type>\t<status>\t<dev_name>"
            let first = &connected[0];
            let key = first.split('\t').next().unwrap_or(first).to_string();
            Ok(key)
        } else {
            Err(Error::new(
                ErrorKind::NotFound,
                format!(
                    "Multiple devices connected, please specify target with -t option:\n{}",
                    connected.join("\n")
                ),
            ))
        }
    } else {
        Ok(connect_key.to_string())
    }
}

/// Resolve a target connect key to a session id, honoring `-t` selection and
/// returning a clear error when there are multiple devices and no target was
/// specified.
async fn resolve_session_id(connect_map: &ConnectMap, connect_key: &str) -> io::Result<u32> {
    let actual_key = resolve_connect_key(connect_map, connect_key).await?;
    connect_map
        .get_session_id(&actual_key)
        .await
        .ok_or_else(|| Error::new(ErrorKind::NotFound, format!("Device {actual_key} is not connected")))
}

// ============================================================================
// TcpMap - manages TCP writers for sessions and channels
// ============================================================================

#[derive(Default)]
struct TcpMapInner {
    session_writers: HashMap<u32, tokio::net::tcp::OwnedWriteHalf>,
    session_ciphers: HashMap<u32, Arc<tokio::sync::Mutex<hdc_protocol::encrypt::PskCipher>>>,
    channel_writers: HashMap<u32, tokio::net::tcp::OwnedWriteHalf>,
    // Track which session each client channel belongs to so we can close them on USB disconnect.
    channel_sessions: HashMap<u32, u32>,
    // Channels marked keep-alive will not be auto-closed after command completion.
    keep_alive_channels: HashSet<u32>,
}

#[derive(Clone)]
pub struct TcpMap {
    inner: Arc<Mutex<TcpMapInner>>,
}

impl TcpMap {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(TcpMapInner::default())),
        }
    }

    pub async fn start_session(&self, id: u32, wr: tokio::net::tcp::OwnedWriteHalf) {
        let mut guard = self.inner.lock().await;
        guard.session_writers.insert(id, wr);
        info!("tcp session start {id}");
    }

    pub async fn start_channel(&self, id: u32, wr: tokio::net::tcp::OwnedWriteHalf) {
        let mut guard = self.inner.lock().await;
        guard.channel_writers.insert(id, wr);
        info!("tcp channel start {id}");
    }

    pub async fn end_session(&self, id: u32) {
        let mut guard = self.inner.lock().await;
        if let Some(mut wr) = guard.session_writers.remove(&id) {
            let _ = wr.shutdown().await;
        }
        info!("tcp session end {id}");
    }

    pub async fn end_channel(&self, id: u32) {
        let mut guard = self.inner.lock().await;
        guard.keep_alive_channels.remove(&id);
        if let Some(mut wr) = guard.channel_writers.remove(&id) {
            let _ = wr.shutdown().await;
        }
        info!("tcp channel end {id}");
    }

    pub async fn set_keep_alive(&self, channel_id: u32) {
        let mut guard = self.inner.lock().await;
        guard.keep_alive_channels.insert(channel_id);
    }

    pub async fn is_keep_alive(&self, channel_id: u32) -> bool {
        let guard = self.inner.lock().await;
        guard.keep_alive_channels.contains(&channel_id)
    }

    pub async fn send_to_session(&self, session_id: u32, data: &[u8]) -> io::Result<()> {
        let mut guard = self.inner.lock().await;
        let cipher = guard.session_ciphers.get(&session_id).cloned();
        if let Some(wr) = guard.session_writers.get_mut(&session_id) {
            let (to_write, encrypted) = if let Some(cipher) = cipher {
                let mut cipher = cipher.lock().await;
                let ct = cipher.encrypt(data)?;
                (ct, true)
            } else {
                (data.to_vec(), false)
            };
            if encrypted {
                let len_bytes = (to_write.len() as u32).to_be_bytes();
                wr.write_all(&len_bytes).await?;
            }
            wr.write_all(&to_write).await?;
            Ok(())
        } else {
            Err(Error::new(ErrorKind::NotFound, "session not found"))
        }
    }

    pub async fn set_session_cipher(&self, session_id: u32, cipher: hdc_protocol::encrypt::PskCipher) {
        let mut guard = self.inner.lock().await;
        guard.session_ciphers.insert(session_id, Arc::new(tokio::sync::Mutex::new(cipher)));
        info!("tcp session {session_id} encryption enabled");
    }

    pub async fn get_session_cipher(&self, session_id: u32) -> Option<Arc<tokio::sync::Mutex<hdc_protocol::encrypt::PskCipher>>> {
        let guard = self.inner.lock().await;
        guard.session_ciphers.get(&session_id).cloned()
    }

    pub async fn send_channel_message(&self, channel_id: u32, data: &[u8]) -> io::Result<()> {
        let mut guard = self.inner.lock().await;
        if let Some(wr) = guard.channel_writers.get_mut(&channel_id) {
            let len_bytes = (data.len() as u32).to_be_bytes();
            wr.write_all(&len_bytes).await?;
            wr.write_all(data).await?;
            Ok(())
        } else {
            Err(Error::new(ErrorKind::NotFound, "channel not found"))
        }
    }

    pub async fn take_channel_writer(&self, channel_id: u32) -> Option<tokio::net::tcp::OwnedWriteHalf> {
        let mut guard = self.inner.lock().await;
        guard.channel_sessions.remove(&channel_id);
        guard.channel_writers.remove(&channel_id)
    }

    /// Associate a client channel with a daemon session so we can close it when the device disconnects.
    pub async fn associate_channel_with_session(&self, channel_id: u32, session_id: u32) {
        let mut guard = self.inner.lock().await;
        guard.channel_sessions.insert(channel_id, session_id);
    }

    /// Close all TCP client channels associated with the given session.
    pub async fn close_session_channels(&self, session_id: u32) {
        let mut guard = self.inner.lock().await;
        let channels_to_close: Vec<u32> = guard
            .channel_sessions
            .iter()
            .filter(|(_, sid)| **sid == session_id)
            .map(|(cid, _)| *cid)
            .collect();
        for channel_id in channels_to_close {
            guard.channel_sessions.remove(&channel_id);
            if let Some(mut wr) = guard.channel_writers.remove(&channel_id) {
                let _ = wr.shutdown().await;
                info!("tcp channel {channel_id} closed due to session {session_id} disconnect");
            }
        }
    }
}

// ============================================================================
// ForwardMap - manages port forwarding entries
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ForwardDirection {
    Forward, // fport: host listens, daemon connects
    Reverse, // rport: daemon listens, host connects
}

#[derive(Debug)]
pub struct ForwardEntry {
    pub channel_id: u32,
    pub session_id: u32,
    pub connect_key: String,
    pub direction: ForwardDirection,
    pub task_string: String,
    /// For fport: abort handle to stop the TCP listener task
    pub abort_handle: Option<tokio::task::AbortHandle>,
}

pub type ForwardMap = Arc<Mutex<HashMap<String, ForwardEntry>>>;

// ============================================================================
// UsbMap - manages USB session senders
// ============================================================================

#[derive(Default)]
struct UsbMapInner {
    session_senders: HashMap<u32, tokio::sync::mpsc::UnboundedSender<Vec<u8>>>,
    // For routing daemon responses to specific tasks (file transfer, app install, shell, forward)
    response_channels: HashMap<(u32, u32), tokio::sync::mpsc::UnboundedSender<TaskMessage>>,
}

#[derive(Clone)]
pub struct UsbMap {
    inner: Arc<Mutex<UsbMapInner>>,
}

impl UsbMap {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(UsbMapInner::default())),
        }
    }

    pub async fn start_session(&self, id: u32, tx: tokio::sync::mpsc::UnboundedSender<Vec<u8>>) {
        let mut guard = self.inner.lock().await;
        guard.session_senders.insert(id, tx);
        info!("usb session start {id}");
    }

    pub async fn end_session(&self, id: u32) {
        let mut guard = self.inner.lock().await;
        guard.session_senders.remove(&id);
        info!("usb session end {id}");
    }

    /// End a USB session and drop all response channels registered for it.
    /// This unblocks any tasks waiting on rx.recv() for those channels.
    pub async fn end_session_with_cleanup(&self, id: u32) {
        let mut guard = self.inner.lock().await;
        guard.session_senders.remove(&id);
        // Drop all response channel senders for this session so receivers get None.
        guard.response_channels.retain(|(sid, _), _| *sid != id);
        info!("usb session end {id} with response channel cleanup");
    }

    pub async fn send_to_session(&self, session_id: u32, data: &[u8]) -> io::Result<()> {
        let guard = self.inner.lock().await;
        if let Some(tx) = guard.session_senders.get(&session_id) {
            tx.send(data.to_vec())
                .map_err(|_| Error::new(ErrorKind::BrokenPipe, "usb session closed"))?;
            Ok(())
        } else {
            Err(Error::new(ErrorKind::NotFound, "usb session not found"))
        }
    }

    /// Register a response channel for a specific (session_id, channel_id).
    /// Daemon responses matching this key will be routed here instead of to TCP clients.
    pub async fn register_response_channel(&self, session_id: u32, channel_id: u32, tx: tokio::sync::mpsc::UnboundedSender<TaskMessage>) {
        let mut guard = self.inner.lock().await;
        guard.response_channels.insert((session_id, channel_id), tx);
    }

    pub async fn unregister_response_channel(&self, session_id: u32, channel_id: u32) {
        let mut guard = self.inner.lock().await;
        guard.response_channels.remove(&(session_id, channel_id));
    }

    /// Try to route a daemon response to a registered channel.
    /// Returns true if routed, false if no channel was registered (should go to TCP client).
    pub async fn route_response(&self, session_id: u32, channel_id: u32, task: TaskMessage) -> bool {
        let guard = self.inner.lock().await;
        if let Some(tx) = guard.response_channels.get(&(session_id, channel_id)) {
            let _ = tx.send(task);
            true
        } else {
            false
        }
    }
}

// ============================================================================
// Server main logic
// ============================================================================

pub async fn run_server_mode(
    addr_str: &str,
    connect_map: ConnectMap,
    tcp_map: TcpMap,
    usb_map: UsbMap,
) -> io::Result<()> {
    // Normalize IPv4-mapped/unbracketed IPv6 forms (e.g. "::ffff:127.0.0.1:8710"
    // as shown by netstat), then create the socket in the address's own family.
    let addr: std::net::SocketAddr = crate::parser::normalize_listen_addr(addr_str)
        .parse()
        .map_err(|e| {
            Error::new(ErrorKind::InvalidInput, format!("Invalid server address: {e}"))
        })?;
    let socket = match addr {
        std::net::SocketAddr::V4(_) => tokio::net::TcpSocket::new_v4()?,
        std::net::SocketAddr::V6(_) => tokio::net::TcpSocket::new_v6()?,
    };
    socket.set_reuseaddr(true)?;
    socket.bind(addr)?;
    let listener = socket.listen(128)?;
    // 成功bind/listen才发布就绪端口，避免异步启动时连接到旧服务。
    crate::report_listening(listener.local_addr()?.port());
    info!("server binds on {addr_str}");

    let forward_map: ForwardMap = Arc::new(Mutex::new(HashMap::new()));
    // 私有服务同一时刻最多32条客户端连接，认证之前也消耗限额，避免无限认证等待。
    let client_limit = Arc::new(tokio::sync::Semaphore::new(32));

    // Start USB device monitor
    let cm = connect_map.clone();
    let tm = tcp_map.clone();
    let um = usb_map.clone();
    let fm = forward_map.clone();
    if USB_DISCOVERY_ENABLED.load(std::sync::atomic::Ordering::Relaxed) {
        tokio::spawn(usb_device_monitor(cm, tm, um, fm));
    }

    loop {
        let (mut stream, addr) = listener.accept().await?;
        let permit = match client_limit.clone().try_acquire_owned() { Ok(permit) => permit, Err(_) => continue };
        info!("accepted client {addr}");
        let cm = connect_map.clone();
        let tm = tcp_map.clone();
        let um = usb_map.clone();
        let fm = forward_map.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let _ = stream.set_nodelay(true);
            // 先校验本进程私有接入，再发送banner或识别协议；拒绝外部应用借用已授权host。
            if crate::admission::accept(&mut stream).await.is_err() { return; }
            // Detect DevEco Studio protocol: it sends a flat 48-byte header with
            // "OHOS HDC" at offsets 4-11 and a length char ',' (0x2C) at offset 3.
            // The standard hdc client waits for the server handshake before responding,
            // so a full 48-byte peek that matches this pattern identifies DevEco.
            let mut peek_buf = [0u8; 48];
            let is_deveco = match tokio::time::timeout(
                tokio::time::Duration::from_millis(800),
                stream.peek(&mut peek_buf),
            )
            .await
            {
                Ok(Ok(n)) if n == 48 => {
                    let magic = std::str::from_utf8(&peek_buf[4..12]).unwrap_or("");
                    let detected = peek_buf[3] == 0x2C && magic == "OHOS HDC";
                    info!(
                        "peeked 48 bytes: first=[{:02x},{:02x},{:02x},{:02x}], magic={magic:?}, deveco={detected}",
                        peek_buf[0], peek_buf[1], peek_buf[2], peek_buf[3]
                    );
                    detected
                }
                Ok(Ok(n)) => {
                    info!("peeked {n} bytes, not a full DevEco header");
                    false
                }
                Ok(Err(e)) => {
                    info!("peek error: {e}");
                    false
                }
                Err(_) => {
                    info!("peek timeout, treating as standard hdc client");
                    false
                }
            };

            let result = if is_deveco {
                info!("detected DevEco Studio client protocol");
                handle_deveco_client(stream, cm, tm, um, fm).await
            } else {
                handle_client(stream, cm, tm, um, fm).await
            };
            if let Err(e) = result {
                // Most errors here are normal disconnects (e.g. DevEco Studio closing
                // the IDE socket or the target device going away). Log at warn level.
                warn!("client handler ended: {e}");
            }
        });
    }
}

async fn handle_client(
    stream: TcpStream,
    connect_map: ConnectMap,
    tcp_map: TcpMap,
    usb_map: UsbMap,
    forward_map: ForwardMap,
) -> io::Result<()> {
    let (mut rd, wr) = stream.into_split();
    let channel_id = rand::random::<u32>();
    tcp_map.start_channel(channel_id, wr).await;

    // Send handshake
    let handshake = [
        HANDSHAKE_MESSAGE.as_bytes(),
        &vec![0u8; BANNER_SIZE - HANDSHAKE_MESSAGE.len()][..],
        &channel_id.to_le_bytes()[..],
        &vec![0u8; KEY_MAX_SIZE - 4][..],
    ]
    .concat();

    tcp_map.send_channel_message(channel_id, &handshake).await?;

    // Receive first message from client.
    // DevEco Studio clients (DeviceMonitor, DeviceAppClientMonitor) do not send
    // a handshake response; they send commands or a flat 48-byte header directly.
    let recv = match recv_channel_message(&mut rd).await {
        Ok(r) => r,
        Err(_) => {
            tcp_map.end_channel(channel_id).await;
            return Ok(());
        }
    };

    info!(
        "handle_client first recv: len={}, bytes12_32={:?}",
        recv.len(),
        &recv.get(12..32).unwrap_or(&[])
    );

    let mut connect_key = String::new();
    let mut pending_msg = None;
    if recv.starts_with(HANDSHAKE_MESSAGE.as_bytes()) {
        // Standard hdc client sends back the handshake response.
        match unpack_channel_handshake(&recv) {
            Ok(key) => {
                connect_key = if key.is_empty() {
                    "any".to_string()
                } else {
                    key
                };
                info!("handle_client unpacked connect_key: '{connect_key}'");
            }
            Err(e) => {
                warn!("invalid handshake response, treating as command: {e}");
                pending_msg = Some(recv);
            }
        }
    } else {
        // DevEco client sends commands (e.g. empty command or getHeadData)
        // without a standard handshake response.
        info!("handle_client first recv does not start with OHOS HDC, treating as command");
        pending_msg = Some(recv);
    }

    // Now handle commands from the client
    loop {
        let recv = if let Some(msg) = pending_msg.take() {
            msg
        } else {
            match recv_channel_message(&mut rd).await {
                Ok(r) => r,
                Err(_) => break,
            }
        };
        let recv_str = String::from_utf8_lossy(&recv);
        info!("recv from client: {recv_str}");

        // Parse the command and forward to device
        let parsed = crate::parser::split_opt_and_cmd(
            recv_str.split(' ').map(|s| s.trim_end_matches('\0').to_string()).collect(),
        );

        if let Some(cmd) = parsed.command {
            // Check for interactive shell
            if cmd == HdcCommand::UnityExecute && parsed.parameters.len() == 1 {
                let actual_key = match resolve_connect_key(&connect_map, &connect_key).await {
                    Ok(k) => k,
                    Err(e) => {
                        let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
                        break;
                    }
                };
                if let Some(wr) = tcp_map.take_channel_writer(channel_id).await {
                    let cm = connect_map.clone();
                    let um = usb_map.clone();
                    tokio::spawn(run_server_shell_bridge(
                        rd, wr, cm, um, actual_key, channel_id
                    ));
                    return Ok(());
                }
            }
            if let Err(e) = dispatch_task(&connect_map, &tcp_map, &usb_map, &forward_map, cmd, &connect_key, channel_id, &parsed.parameters).await {
                error!("dispatch task failed: {e}");
                let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
            }
        } else {
            // DevEco Studio's DeviceMonitor sends "alive" after the handshake
            // as a keep-alive probe and does not consume the response.
            // Sending any response here confuses DeviceMonitor's BufferedReader,
            // causing it to read the alive response instead of the device list.
            let trimmed = recv_str.trim_end_matches('\0').trim();
            if !trimmed.is_empty() && trimmed != "alive" {
                let _ = tcp_map.send_channel_message(channel_id, b"[Fail][E001001]Unknown command\r\n").await;
            }
            continue;
        }
    }

    tcp_map.end_channel(channel_id).await;
    Ok(())
}

/// Handle DevEco Studio client connections.
/// Protocol:
///   1. Client sends 48-byte header: [len-char]["OHOS HDC"][connectKey(zero-padded)]
///   2. Server echoes 48-byte header with "OHOS HDC" at offsets 4-11
///   3. Commands: [4-byte BE length][command string][\0]
///   4. Responses: [4-byte BE length][data]
async fn handle_deveco_client(
    mut stream: TcpStream,
    connect_map: ConnectMap,
    tcp_map: TcpMap,
    usb_map: UsbMap,
    forward_map: ForwardMap,
) -> io::Result<()> {
    // Use owned halves so the JDWP streaming handler can take the socket.
    let (mut rd, mut wr) = stream.into_split();

    // Read 48-byte header
    let mut head_buf = [0u8; 48];
    rd.read_exact(&mut head_buf).await?;

    // Validate "OHOS HDC" at offset 4
    let magic = std::str::from_utf8(&head_buf[4..12]).unwrap_or("");
    if magic != "OHOS HDC" {
        return Err(Error::new(
            ErrorKind::InvalidData,
            format!("invalid DevEco handshake magic: {magic:?}"),
        ));
    }

    // Send 48-byte response: mirror the header back
    wr.write_all(&head_buf).await?;
    wr.flush().await?;

    // Command loop
    loop {
        // Read 4-byte BE length
        let mut len_buf = [0u8; 4];
        match rd.read_exact(&mut len_buf).await {
            Ok(_) => {}
            Err(ref e) if e.kind() == ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(e),
        }
        let cmd_len = u32::from_be_bytes(len_buf) as usize;
        if cmd_len == 0 || cmd_len > 1024 * 1024 {
            return Err(Error::new(ErrorKind::InvalidData, "invalid command length"));
        }

        // Read command (includes trailing \0)
        let mut cmd_buf = vec![0u8; cmd_len];
        rd.read_exact(&mut cmd_buf).await?;
        let cmd_str = String::from_utf8_lossy(&cmd_buf);
        let cmd = cmd_str.trim_end_matches('\0').trim();
        info!("DevEco command: {cmd}");

        // `track-jpid` is a continuous stream: the daemon keeps sending updates
        // until the client closes the channel. Hand the socket over to a
        // dedicated streaming handler instead of collecting a one-shot response.
        let parsed = crate::parser::split_opt_and_cmd(
            cmd.split(' ').map(|s| s.to_string()).collect(),
        );
        if parsed.command == Some(HdcCommand::JdwpTrack) {
            return handle_deveco_jdwp_track(rd, wr, connect_map, usb_map, parsed.parameters).await;
        }

        // Execute command and send response
        let response = execute_deveco_command(cmd, &connect_map, tcp_map.clone(), usb_map.clone(), forward_map.clone()).await;
        let mut resp_bytes = response.into_bytes();
        // Append newline so BufferedReader.readLine() terminates cleanly
        if !resp_bytes.is_empty() && !resp_bytes.ends_with(b"\n") {
            resp_bytes.push(b'\n');
        }
        let resp_len = resp_bytes.len() as u32;
        let mut resp_packet = Vec::with_capacity(4 + resp_len as usize);
        resp_packet.extend_from_slice(&resp_len.to_be_bytes());
        resp_packet.extend_from_slice(&resp_bytes);
        wr.write_all(&resp_packet).await?;
        wr.flush().await?;
    }

    Ok(())
}

/// Stream JDWP process-tracking responses from the daemon to a DevEco Studio
/// client. The daemon sends `KernelEcho` messages whose payload begins with a
/// log-level byte; we strip it so the IDE receives the raw ASCII-hex length
/// header it expects.
async fn handle_deveco_jdwp_track(
    mut rd: tokio::net::tcp::OwnedReadHalf,
    mut wr: tokio::net::tcp::OwnedWriteHalf,
    connect_map: ConnectMap,
    usb_map: UsbMap,
    params: Vec<String>,
) -> io::Result<()> {
    let session_id = match connect_map.get_session_id("any").await {
        Some(id) => id,
        None => {
            let _ = wr.write_all(b"[Fail]No device connected\r\n").await;
            let _ = wr.shutdown().await;
            return Ok(());
        }
    };

    let channel_id = rand::random::<u32>();
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<TaskMessage>();
    usb_map.register_response_channel(session_id, channel_id, tx).await;

    // Send JdwpTrack command to daemon. Match official host behavior: only the
    // option character ("a" or "p") is sent as the payload.
    let payload = if params.iter().any(|p| p == "-a") {
        b"a".to_vec()
    } else if params.iter().any(|p| p == "-p") {
        b"p".to_vec()
    } else {
        vec![]
    };
    let msg = TaskMessage {
        channel_id,
        command: HdcCommand::JdwpTrack,
        payload,
    };
    let data = concat_pack(&msg);
    if let Err(e) = usb_map.send_to_session(session_id, &data).await {
        let _ = wr.write_all(format!("[Fail]Send to daemon failed: {e}\r\n").as_bytes()).await;
        let _ = wr.shutdown().await;
        usb_map.unregister_response_channel(session_id, channel_id).await;
        return Ok(());
    }

    // Forward daemon responses to the IDE client as length-prefixed raw data.
    let mut wr_for_daemon = wr;
    let daemon_reader = tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Some(task) => {
                    if task.command == HdcCommand::KernelChannelClose {
                        let _ = wr_for_daemon.shutdown().await;
                        break;
                    }
                    let payload = if task.command == HdcCommand::KernelEcho && !task.payload.is_empty() {
                        &task.payload[1..]
                    } else {
                        &task.payload[..]
                    };
                    let packet = [&(payload.len() as u32).to_be_bytes()[..], payload].concat();
                    if wr_for_daemon.write_all(&packet).await.is_err() {
                        let _ = wr_for_daemon.shutdown().await;
                        break;
                    }
                }
                None => {
                    let _ = wr_for_daemon.shutdown().await;
                    break;
                }
            }
        }
    });

    // Keep the channel alive while the IDE client holds the socket open.
    // `DeviceAppClientMonitor` does not send further commands on this socket.
    let mut discard = [0u8; 256];
    loop {
        match rd.read(&mut discard).await {
            Ok(0) => break,
            Ok(_) => continue,
            Err(_) => break,
        }
    }

    let _ = daemon_reader.await;
    usb_map.unregister_response_channel(session_id, channel_id).await;
    Ok(())
}

async fn execute_deveco_command(
    cmd: &str,
    connect_map: &ConnectMap,
    tcp_map: TcpMap,
    usb_map: UsbMap,
    forward_map: ForwardMap,
) -> String {
    if cmd == "alive" {
        return String::new();
    }

    if cmd == "list targets" {
        let list = connect_map.get_list(false).await;
        return list.join("\n");
    }

    if cmd == "list targets -v" {
        let list = connect_map.get_list(true).await;
        let mut result = String::new();
        for line in list {
            let parts: Vec<&str> = line.split('\t').filter(|s| !s.is_empty()).collect();
            if parts.len() >= 4 {
                let serial = parts[0];
                let conn_type = parts[1];
                let status = parts[2];
                if !result.is_empty() {
                    result.push('\n');
                }
                result.push_str(serial);
                result.push(' ');
                result.push_str(conn_type);
                result.push(' ');
                result.push_str(status);
            }
        }
        return result;
    }

    // Parse the command string into params to determine the HdcCommand
    let params: Vec<String> = cmd.split(' ').map(|s| s.to_string()).collect();
    let parsed = crate::parser::split_opt_and_cmd(params.clone());

    if let Some(hdc_cmd) = parsed.command {
        match hdc_cmd {
            HdcCommand::UnityExecute | HdcCommand::UnityExecuteEx => {
                if parsed.parameters.len() == 1 {
                    // Interactive shell is not supported over the IDE socket
                    return "[Fail]Interactive shell is not supported over IDE socket\r\n".to_string();
                }
                return forward_command_to_daemon(
                    connect_map, tcp_map, usb_map, forward_map, hdc_cmd, params, 30,
                ).await;
            }
            HdcCommand::FileInit | HdcCommand::FileRecvInit => {
                let mut adjusted = params;
                if adjusted.len() >= 2 && adjusted[1] == "send" {
                    // Insert -cwd for file send so the server resolves relative paths
                    let cwd = std::env::current_dir()
                        .map(|p| p.display().to_string())
                        .unwrap_or_default();
                    adjusted.insert(2, "-cwd".to_string());
                    adjusted.insert(3, cwd);
                }
                return forward_command_to_daemon(
                    connect_map, tcp_map, usb_map, forward_map, hdc_cmd, adjusted, 300,
                ).await;
            }
            HdcCommand::AppInit | HdcCommand::AppUninstall
            | HdcCommand::ForwardInit | HdcCommand::ForwardRportInit
            | HdcCommand::ForwardList | HdcCommand::ForwardRportList
            | HdcCommand::ForwardRemove | HdcCommand::ForwardRportRemove
            | HdcCommand::JdwpList | HdcCommand::JdwpTrack
            | HdcCommand::UnityRunmode | HdcCommand::UnityReboot
            | HdcCommand::UnityRemount | HdcCommand::UnityRootrun
            | HdcCommand::UnityHilog | HdcCommand::UnityBugreportInit => {
                return forward_command_to_daemon(
                    connect_map, tcp_map, usb_map, forward_map, hdc_cmd, params, 60,
                ).await;
            }
            _ => {}
        }
    }

    format!("[Fail]Unknown command: {cmd}\r\n")
}

/// Forward a command to the default connected daemon using the existing dispatch_task logic
/// and capture the output via a loopback TCP channel.
async fn forward_command_to_daemon(
    connect_map: &ConnectMap,
    tcp_map: TcpMap,
    usb_map: UsbMap,
    forward_map: ForwardMap,
    command: HdcCommand,
    params: Vec<String>,
    timeout_secs: u64,
) -> String {
    let connect_key = match get_default_connect_key(connect_map).await {
        Some(k) => k,
        None => return "[Fail]No device connected\r\n".to_string(),
    };

    let channel_id = rand::random::<u32>();

    // Create a loopback TCP pair so dispatch_task can write to a real channel writer
    let listener = match tokio::net::TcpListener::bind("127.0.0.1:0").await {
        Ok(l) => l,
        Err(e) => return format!("[Fail]Failed to bind loopback: {e}\r\n"),
    };
    let addr = match listener.local_addr() {
        Ok(a) => a,
        Err(e) => return format!("[Fail]Failed to get loopback addr: {e}\r\n"),
    };

    let client_stream = match tokio::net::TcpStream::connect(addr).await {
        Ok(s) => s,
        Err(e) => return format!("[Fail]Failed to connect loopback: {e}\r\n"),
    };
    let (client_rd, _client_wr) = client_stream.into_split();

    let (server_stream, _) = match listener.accept().await {
        Ok(s) => s,
        Err(e) => return format!("[Fail]Failed to accept loopback: {e}\r\n"),
    };
    let (server_rd, server_wr) = server_stream.into_split();

    // Register the server writer as this virtual channel
    tcp_map.start_channel(channel_id, server_wr).await;

    // Spawn dispatch_task to handle the command using existing server logic
    let cm = connect_map.clone();
    let tm = tcp_map.clone();
    let um = usb_map.clone();
    let fm = forward_map.clone();
    let dispatch_handle = tokio::spawn(async move {
        let _ = dispatch_task(&cm, &tm, &um, &fm, command, &connect_key, channel_id, &params).await;
        // Do NOT forcibly close the channel here. Commands that end locally
        // (e.g. list targets) already call maybe_end_channel. Commands that
        // forward to the daemon (e.g. shell) rely on the daemon's
        // KernelChannelClose to close the channel, so the loopback reader
        // can capture the full daemon output before EOF.
    });

    // Read all output from the client side of the loopback.
    // The server side writes length-prefixed HDC channel messages, so decode
    // them here instead of returning raw bytes. Use a short idle timeout so
    // commands whose daemon does not send KernelChannelClose still finish.
    let mut output = Vec::new();
    let read_result = tokio::time::timeout(
        tokio::time::Duration::from_secs(timeout_secs),
        read_loopback_messages(client_rd, &mut output, tokio::time::Duration::from_secs(2)),
    )
    .await;

    // Wait for dispatch_task to finish
    let _ = dispatch_handle.await;

    match read_result {
        Ok(Ok(())) | Ok(Err(_)) => {}
        Err(_) => {
            if output.is_empty() {
                return "[Fail]Command timed out\r\n".to_string();
            }
        }
    }

    String::from_utf8_lossy(&output).to_string()
}

async fn read_loopback_output(
    mut rd: tokio::net::tcp::OwnedReadHalf,
    output: &mut Vec<u8>,
) -> io::Result<()> {
    let mut buf = [0u8; 8192];
    loop {
        match rd.read(&mut buf).await {
            Ok(0) => break,
            Ok(n) => output.extend_from_slice(&buf[..n]),
            Err(e) if e.kind() == ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

/// Read length-prefixed HDC channel messages from the loopback client side
/// and append the payload bytes (without length prefix) to `output`.
/// If no new data arrives within `idle_timeout`, the function returns Ok so
/// commands whose daemon does not send KernelChannelClose still produce output.
async fn read_loopback_messages(
    mut rd: tokio::net::tcp::OwnedReadHalf,
    output: &mut Vec<u8>,
    idle_timeout: tokio::time::Duration,
) -> io::Result<()> {
    let mut len_buf = [0u8; 4];
    loop {
        // Read 4-byte BE length with idle timeout
        let mut read = 0;
        while read < 4 {
            match tokio::time::timeout(idle_timeout, rd.read(&mut len_buf[read..])).await {
                Ok(Ok(0)) => return Ok(()),
                Ok(Ok(n)) => read += n,
                Ok(Err(e)) if e.kind() == ErrorKind::UnexpectedEof => return Ok(()),
                Ok(Err(e)) => return Err(e),
                Err(_) => return Ok(()),
            }
        }
        let len = u32::from_be_bytes(len_buf) as usize;
        if len > 16 * 1024 * 1024 {
            return Err(Error::new(ErrorKind::InvalidData, "loopback message too large"));
        }
        // Read payload
        let mut payload = vec![0u8; len];
        let mut read = 0;
        while read < len {
            match tokio::time::timeout(idle_timeout, rd.read(&mut payload[read..])).await {
                Ok(Ok(0)) => return Ok(()),
                Ok(Ok(n)) => read += n,
                Ok(Err(e)) if e.kind() == ErrorKind::UnexpectedEof => return Ok(()),
                Ok(Err(e)) => return Err(e),
                Err(_) => return Ok(()),
            }
        }
        output.extend_from_slice(&payload);
    }
}

/// Register a response channel, forward daemon replies to the TCP channel, and
/// close the channel after a short idle period. Used for commands like
/// AppUninstall where the daemon replies but never sends KernelChannelClose.
async fn collect_daemon_response_then_close(
    tcp_map: &TcpMap,
    usb_map: &UsbMap,
    session_id: u32,
    channel_id: u32,
) {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<TaskMessage>();
    usb_map.register_response_channel(session_id, channel_id, tx).await;

    let idle = tokio::time::Duration::from_secs(2);
    loop {
        match tokio::time::timeout(idle, rx.recv()).await {
            Ok(Some(task)) => {
                if task.command == HdcCommand::KernelChannelClose {
                    break;
                }
                let text = String::from_utf8_lossy(&task.payload);
                let _ = tcp_map.send_channel_message(channel_id, text.as_bytes()).await;
            }
            Ok(None) | Err(_) => break,
        }
    }

    usb_map.unregister_response_channel(session_id, channel_id).await;
    maybe_end_channel(tcp_map, channel_id).await;
}

async fn get_default_connect_key(connect_map: &ConnectMap) -> Option<String> {
    let list = connect_map.get_list(true).await;
    for entry in list {
        let parts: Vec<&str> = entry.split('\t').filter(|s| !s.is_empty()).collect();
        if parts.len() >= 3 && parts[2] == "Connected" {
            return Some(parts[0].to_string());
        }
    }
    // Fallback: any device
    let list = connect_map.get_list(false).await;
    list.into_iter().next()
}

/// Legacy simple forwarder for commands that do not need dispatch_task interactions.
/// Prefer forward_command_to_daemon for new commands.
async fn forward_simple_command(
    connect_map: &ConnectMap,
    tcp_map: TcpMap,
    usb_map: UsbMap,
    command: HdcCommand,
    payload: &str,
) -> String {
    let session_id = match connect_map.get_session_id("any").await {
        Some(id) => id,
        None => return "[Fail]No device connected\r\n".to_string(),
    };

    let channel_id = rand::random::<u32>();
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<TaskMessage>();

    usb_map.register_response_channel(session_id, channel_id, tx.clone()).await;

    let task = TaskMessage {
        channel_id,
        command,
        payload: payload.as_bytes().to_vec(),
    };
    let data = concat_pack(&task);

    let send_result = if tcp_map.send_to_session(session_id, &data).await.is_ok() {
        Ok(())
    } else {
        usb_map.send_to_session(session_id, &data).await
    };

    if let Err(e) = send_result {
        usb_map.unregister_response_channel(session_id, channel_id).await;
        return format!("[Fail]Failed to send command to device: {e}\r\n");
    }

    let mut output = String::new();
    let deadline = tokio::time::Instant::now() + tokio::time::Duration::from_secs(10);
    loop {
        match tokio::time::timeout_at(deadline, rx.recv()).await {
            Ok(Some(msg)) => {
                if msg.command == HdcCommand::KernelChannelClose {
                    break;
                }
                if let Ok(text) = std::str::from_utf8(&msg.payload) {
                    output.push_str(text);
                } else {
                    output.push_str(&format!("[binary {} bytes]", msg.payload.len()));
                }
            }
            Ok(None) => break,
            Err(_) => {
                if output.is_empty() {
                    output.push_str("[Fail]Command timed out\r\n");
                }
                break;
            }
        }
    }

    usb_map.unregister_response_channel(session_id, channel_id).await;
    output
}

async fn recv_channel_message(rd: &mut tokio::net::tcp::OwnedReadHalf) -> io::Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    rd.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    let mut data = vec![0u8; len];
    rd.read_exact(&mut data).await?;
    Ok(data)
}

fn unpack_channel_handshake(recv: &[u8]) -> io::Result<String> {
    let msg = std::str::from_utf8(&recv[..HANDSHAKE_MESSAGE.len()])
        .map_err(|_| Error::new(ErrorKind::InvalidData, "not utf-8 chars"))?;
    if msg != HANDSHAKE_MESSAGE {
        return Err(Error::new(ErrorKind::InvalidData, "Recv server-hello failed"));
    }
    let key_buf = &recv[BANNER_SIZE..];
    // DevEco Studio's 48-byte header has zero padding between the banner and the
    // serial number, so skip leading zeros before looking for the key.
    let start = key_buf.iter().position(|&c| c != 0).unwrap_or(0);
    let trimmed = &key_buf[start..];
    let pos = trimmed.iter().position(|&c| c == 0).unwrap_or(trimmed.len());
    String::from_utf8(trimmed[..pos].to_vec())
        .map_err(|_| Error::new(ErrorKind::InvalidData, "unpack connect key failed"))
}

/// Parse TLV string into a map. Format: tag(16 bytes, space-padded) + val_len(16 bytes, space-padded) + value.
fn parse_tlv(tlv: &str) -> std::collections::HashMap<String, String> {
    const TAG_LEN: usize = 16;
    const VAL_LEN: usize = 16;
    const MIN_LEN: usize = TAG_LEN + VAL_LEN;
    let mut map = std::collections::HashMap::new();
    let mut remaining = tlv;
    while remaining.len() >= MIN_LEN {
        let tag = remaining[..TAG_LEN].trim_end().to_string();
        let val_len_str = remaining[TAG_LEN..MIN_LEN].trim_end();
        let val_len: usize = match val_len_str.parse() {
            Ok(n) => n,
            Err(_) => break,
        };
        remaining = &remaining[MIN_LEN..];
        if remaining.len() < val_len {
            break;
        }
        let val = remaining[..val_len].to_string();
        remaining = &remaining[val_len..];
        map.insert(tag, val);
    }
    map
}

/// Close channel only if keepAlive is not set. Used for commands that normally auto-close.
async fn maybe_end_channel(tcp_map: &TcpMap, channel_id: u32) {
    if !tcp_map.is_keep_alive(channel_id).await {
        tcp_map.end_channel(channel_id).await;
    }
}

/// Send a framed HDC message to a daemon session, preferring the TCP writer map
/// and falling back to the USB session map so that file/app/forward handlers work
/// over both transports.
async fn send_to_session(
    tcp_map: &TcpMap,
    usb_map: &UsbMap,
    session_id: u32,
    data: &[u8],
) -> io::Result<()> {
    if tcp_map.send_to_session(session_id, data).await.is_ok() {
        return Ok(());
    }
    usb_map.send_to_session(session_id, data).await
}

async fn dispatch_task(
    connect_map: &ConnectMap,
    tcp_map: &TcpMap,
    usb_map: &UsbMap,
    forward_map: &ForwardMap,
    cmd: HdcCommand,
    connect_key: &str,
    channel_id: u32,
    params: &[String],
) -> io::Result<()> {
    info!("dispatch_task: cmd={:?}, connect_key='{connect_key}', params={:?}", cmd, params);
    match cmd {
        HdcCommand::KernelTargetList => {
            let is_full = params.iter().any(|p| p == "v" || p == "-v");
            let list = connect_map.get_list(is_full).await;
            let msg = if list.is_empty() {
                "[Empty]".to_string()
            } else {
                list.join("\n")
            };
            tcp_map.send_channel_message(channel_id, (msg + "\r\n").as_bytes()).await?;
            maybe_end_channel(tcp_map, channel_id).await;
        }
        HdcCommand::KernelTargetDiscover => {
            let mut count = 0;
            match crate::net_discover::discover_devices().await {
                Ok(addrs) => {
                    for addr in addrs {
                        if connect_map.contains_key(&addr).await {
                            continue;
                        }
                        count += 1;
                        connect_map.put(addr, DaemonInfo {
                            session_id: 0,
                            conn_type: ConnectType::Tcp,
                            conn_status: ConnStatus::Ready,
                            dev_name: String::new(),
                            version: String::new(),
                        }).await;
                    }
                }
                Err(e) => {
                    warn!("Network discovery failed: {e}");
                }
            }
            let msg = format!("Broadcast find daemon, total:{count}\r\n");
            tcp_map.send_channel_message(channel_id, msg.as_bytes()).await?;
            maybe_end_channel(tcp_map, channel_id).await;
        }
        HdcCommand::KernelCheckDevice => {
            let key = if params.len() > 1 {
                &params[1]
            } else {
                connect_key
            };
            let actual_key = match resolve_connect_key(connect_map, key).await {
                Ok(k) => k,
                Err(e) => {
                    tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await?;
                    maybe_end_channel(tcp_map, channel_id).await;
                    return Ok(());
                }
            };
            let status = if connect_map.get_session_id(&actual_key).await.is_some() {
                format!("Device {} is connected\r\n", actual_key)
            } else {
                format!("[Fail]Device {} is not connected\r\n", actual_key)
            };
            tcp_map.send_channel_message(channel_id, status.as_bytes()).await?;
            maybe_end_channel(tcp_map, channel_id).await;
        }
        HdcCommand::KernelTargetConnect => {
            if params.len() < 2 {
                tcp_map.send_channel_message(channel_id, b"[Fail]Missing connect address\r\n").await?;
                maybe_end_channel(tcp_map, channel_id).await;
                return Ok(());
            }
            let addr = params[1].clone();
            match start_tcp_daemon_session(&addr, connect_map, tcp_map, usb_map, channel_id).await {
                Ok(_) => {
                    tcp_map.send_channel_message(channel_id, b"Connect OK\r\n").await?;
                }
                Err(e) => {
                    tcp_map.send_channel_message(channel_id, format!("[Fail]Connect to daemon failed: {e}\r\n").as_bytes()).await?;
                }
            }
            maybe_end_channel(tcp_map, channel_id).await;
        }
        HdcCommand::KernelCheckServer => {
            let payload = [
                &(HdcCommand::KernelCheckServer as u16).to_le_bytes()[..],
                get_version().as_bytes(),
            ].concat();
            tcp_map.send_channel_message(channel_id, &payload).await?;
            maybe_end_channel(tcp_map, channel_id).await;
        }
        HdcCommand::ClientVersion => {
            tcp_map.send_channel_message(channel_id, get_version().as_bytes()).await?;
            maybe_end_channel(tcp_map, channel_id).await;
        }
        HdcCommand::KernelEnableKeepalive => {
            // Official behavior: set hChannel->keepAlive = true, no response sent.
            // This flag prevents server from auto-closing the channel after local commands
            // like 'list targets'. Channel stays open waiting for next command.
            tcp_map.set_keep_alive(channel_id).await;
        }
        HdcCommand::KernelWaitFor => {
            loop {
                let list = connect_map.get_list(false).await;
                if list.is_empty() {
                    tcp_map.send_channel_message(channel_id, b"[Fail]No any connected target\r\n").await?;
                    tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
                } else {
                    let msg = format!("Wait for connected target {}\r\n", list[0]);
                    tcp_map.send_channel_message(channel_id, msg.as_bytes()).await?;
                    break;
                }
            }
            maybe_end_channel(tcp_map, channel_id).await;
        }
        HdcCommand::KernelTargetReconnect => {
            let key = if params.len() > 1 {
                &params[1]
            } else {
                connect_key
            };
            let actual_key = match resolve_connect_key(connect_map, key).await {
                Ok(k) => k,
                Err(e) => {
                    tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await?;
                    maybe_end_channel(tcp_map, channel_id).await;
                    return Ok(());
                }
            };
            if let Some(session_id) = connect_map.get_session_id(&actual_key).await {
                let _ = tcp_map.end_session(session_id).await;
                connect_map.remove(&actual_key).await;
                let msg = format!("Reconnecting {} ...\r\n", actual_key);
                tcp_map.send_channel_message(channel_id, msg.as_bytes()).await?;
            } else {
                tcp_map.send_channel_message(channel_id, format!("[Fail]Device {} is not connected\r\n", actual_key).as_bytes()).await?;
            }
            maybe_end_channel(tcp_map, channel_id).await;
        }
        HdcCommand::SpawnSub => {
            if params.get(0).map(|s| s.as_str()) == Some("killall-sub") {
                tcp_map.send_channel_message(channel_id, b"Kill all subserver processes (not fully implemented)\r\n").await?;
            } else {
                tcp_map.send_channel_message(channel_id, b"Spawn subserver (not fully implemented)\r\n").await?;
            }
            maybe_end_channel(tcp_map, channel_id).await;
        }
        HdcCommand::FileInit => {
            debug!("FileInit: connect_key={}, channel_id={}, params={:?}", connect_key, channel_id, params);
            match resolve_connect_key(connect_map, connect_key).await {
                Ok(actual_key) => {
                    debug!("FileInit: resolved connect_key={}", actual_key);
                    if let Some(session_id) = connect_map.get_session_id(&actual_key).await {
                        debug!("FileInit: session_id={}", session_id);
                        if let Err(e) = handle_server_file_send(tcp_map, usb_map, session_id, channel_id, params).await {
                            warn!("FileInit: handle_server_file_send failed: {}", e);
                            let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
                            maybe_end_channel(tcp_map, channel_id).await;
                        }
                    } else {
                        warn!("FileInit: session not found for key={}", actual_key);
                        let _ = tcp_map.send_channel_message(channel_id, b"[Fail]Session not found\r\n").await;
                        maybe_end_channel(tcp_map, channel_id).await;
                    }
                }
                Err(e) => {
                    warn!("FileInit: resolve_connect_key failed: {}", e);
                    let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
                    maybe_end_channel(tcp_map, channel_id).await;
                }
            }
        }
        HdcCommand::FileRecvInit => {
            match resolve_connect_key(connect_map, connect_key).await {
                Ok(actual_key) => {
                    if let Some(session_id) = connect_map.get_session_id(&actual_key).await {
                        if let Err(e) = handle_server_file_recv(tcp_map, usb_map, session_id, channel_id, params).await {
                            let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
                            maybe_end_channel(tcp_map, channel_id).await;
                        }
                    } else {
                        let _ = tcp_map.send_channel_message(channel_id, b"[Fail]Session not found\r\n").await;
                        maybe_end_channel(tcp_map, channel_id).await;
                    }
                }
                Err(e) => {
                    let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
                    maybe_end_channel(tcp_map, channel_id).await;
                }
            }
        }
        HdcCommand::AppInit => {
            match resolve_connect_key(connect_map, connect_key).await {
                Ok(actual_key) => {
                    if let Some(session_id) = connect_map.get_session_id(&actual_key).await {
                        if let Err(e) = handle_server_app_install(tcp_map, usb_map, session_id, channel_id, params).await {
                            let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
                            maybe_end_channel(tcp_map, channel_id).await;
                        }
                    } else {
                        let _ = tcp_map.send_channel_message(channel_id, b"[Fail]Session not found\r\n").await;
                        maybe_end_channel(tcp_map, channel_id).await;
                    }
                }
                Err(e) => {
                    let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
                    maybe_end_channel(tcp_map, channel_id).await;
                }
            }
        }
        HdcCommand::ForwardInit => {
            match resolve_connect_key(connect_map, connect_key).await {
                Ok(actual_key) => {
                    if let Some(session_id) = connect_map.get_session_id(&actual_key).await {
                        if let Err(e) = handle_server_forward(tcp_map, usb_map, forward_map, &actual_key, session_id, channel_id, params).await {
                            let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
                            maybe_end_channel(tcp_map, channel_id).await;
                        }
                    } else {
                        let _ = tcp_map.send_channel_message(channel_id, b"[Fail]Session not found\r\n").await;
                        maybe_end_channel(tcp_map, channel_id).await;
                    }
                }
                Err(e) => {
                    let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
                    maybe_end_channel(tcp_map, channel_id).await;
                }
            }
        }
        HdcCommand::ForwardRportInit => {
            match resolve_connect_key(connect_map, connect_key).await {
                Ok(actual_key) => {
                    if let Some(session_id) = connect_map.get_session_id(&actual_key).await {
                        if let Err(e) = handle_server_rport(tcp_map, usb_map, forward_map, &actual_key, session_id, channel_id, params).await {
                            let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
                            maybe_end_channel(tcp_map, channel_id).await;
                        }
                    } else {
                        let _ = tcp_map.send_channel_message(channel_id, b"[Fail]Session not found\r\n").await;
                        maybe_end_channel(tcp_map, channel_id).await;
                    }
                }
                Err(e) => {
                    let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
                    maybe_end_channel(tcp_map, channel_id).await;
                }
            }
        }
        HdcCommand::ForwardList | HdcCommand::ForwardRportList => {
            let list = build_forward_list(forward_map, connect_key).await;
            if list.is_empty() {
                let _ = tcp_map.send_channel_message(channel_id, b"[Empty]\r\n").await;
            } else {
                let _ = tcp_map.send_channel_message(channel_id, (list + "\r\n").as_bytes()).await;
            }
            maybe_end_channel(tcp_map, channel_id).await;
        }
        HdcCommand::ForwardRemove | HdcCommand::ForwardRportRemove => {
            // params format: ["fport", "rm", "tcp:19090"] or ["fport", "rm"]
            let spec = if params.len() >= 3 {
                params[2..].join(" ")
            } else {
                String::new()
            };
            match remove_forward_entry(tcp_map, usb_map, forward_map, connect_key, channel_id, &spec).await {
                Ok(msg) => {
                    let _ = tcp_map.send_channel_message(channel_id, (msg + "\r\n").as_bytes()).await;
                }
                Err(e) => {
                    let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
                }
            }
            maybe_end_channel(tcp_map, channel_id).await;
        }
        HdcCommand::JdwpTrack => {
            // Forward track-jpid to the daemon. The official host strips the command
            // name and sends only the option character ("a" or "p"); the daemon uses
            // it to decide the debug/release filter for the streamed process list.
            debug!("dispatch_task: forwarding JdwpTrack to daemon");
            match resolve_session_id(connect_map, connect_key).await {
                Ok(session_id) => {
                let payload = if params.iter().any(|p| p == "-a") {
                    b"a".to_vec()
                } else if params.iter().any(|p| p == "-p") {
                    b"p".to_vec()
                } else {
                    vec![]
                };
                let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<TaskMessage>();
                usb_map.register_response_channel(session_id, channel_id, tx).await;
                let msg = TaskMessage {
                    channel_id,
                    command: cmd,
                    payload,
                };
                if let Err(e) = send_to_session(tcp_map, usb_map, session_id, &concat_pack(&msg)).await {
                    tcp_map.send_channel_message(channel_id, format!("[Fail]Send to daemon failed: {e}\r\n").as_bytes()).await?;
                    maybe_end_channel(tcp_map, channel_id).await;
                    usb_map.unregister_response_channel(session_id, channel_id).await;
                    return Ok(());
                }
                tcp_map.associate_channel_with_session(channel_id, session_id).await;
                // Stream daemon responses back, stripping the KernelEcho log-level byte
                // so DevEco Studio / IDE clients receive the raw ASCII process list.
                let tcp_map_clone = tcp_map.clone();
                let usb_map_clone = usb_map.clone();
                tokio::spawn(async move {
                    while let Some(task) = rx.recv().await {
                        if task.command == HdcCommand::KernelChannelClose {
                            break;
                        }
                        let payload = if task.command == HdcCommand::KernelEcho && !task.payload.is_empty() {
                            &task.payload[1..]
                        } else {
                            &task.payload[..]
                        };
                        if tcp_map_clone.send_channel_message(channel_id, payload).await.is_err() {
                            break;
                        }
                    }
                    let _ = tcp_map_clone.end_channel(channel_id).await;
                    usb_map_clone.unregister_response_channel(session_id, channel_id).await;
                });
            }
            Err(e) => {
                tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await?;
                maybe_end_channel(tcp_map, channel_id).await;
            }
        }
        }
        HdcCommand::JdwpList => {
            debug!("dispatch_task: forwarding JdwpList to daemon");
            match resolve_session_id(connect_map, connect_key).await {
                Ok(session_id) => {
                    let msg = TaskMessage {
                        channel_id,
                        command: cmd,
                        payload: vec![],
                    };
                    let data = concat_pack(&msg);
                    if let Err(e) = send_to_session(tcp_map, usb_map, session_id, &data).await {
                        tcp_map.send_channel_message(channel_id, format!("[Fail]Send to daemon failed: {e}\r\n").as_bytes()).await?;
                        maybe_end_channel(tcp_map, channel_id).await;
                    }
                    tcp_map.associate_channel_with_session(channel_id, session_id).await;
                }
                Err(e) => {
                    tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await?;
                    maybe_end_channel(tcp_map, channel_id).await;
                }
            }
        }
        HdcCommand::FlashdUpdateInit
        | HdcCommand::FlashdFlashInit
        | HdcCommand::FlashdErase
        | HdcCommand::FlashdFormat => {
            debug!("Flashd command: cmd={:?}, connect_key={}, channel_id={}, params={:?}", cmd, connect_key, channel_id, params);
            match resolve_connect_key(connect_map, connect_key).await {
                Ok(actual_key) => {
                    if let Some(session_id) = connect_map.get_session_id(&actual_key).await {
                        if let Err(e) = handle_server_flashd(tcp_map, usb_map, session_id, channel_id, cmd, params).await {
                            let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
                            maybe_end_channel(tcp_map, channel_id).await;
                        }
                    } else {
                        let _ = tcp_map.send_channel_message(channel_id, b"[Fail]Session not found\r\n").await;
                        maybe_end_channel(tcp_map, channel_id).await;
                    }
                }
                Err(e) => {
                    let _ = tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await;
                    maybe_end_channel(tcp_map, channel_id).await;
                }
            }
        }
        _ => {
            warn!("dispatch_task: forwarding cmd={:?}, connect_key='{connect_key}', params={:?}", cmd, params);
            // Fallback: list targets should not reach here, but handle defensively
            if cmd == HdcCommand::KernelTargetList || cmd == HdcCommand::KernelTargetDiscover {
                let is_full = params.iter().any(|p| p == "v" || p == "-v");
                let list = connect_map.get_list(is_full).await;
                let msg = if list.is_empty() {
                    "[Empty]".to_string()
                } else {
                    list.join("\n")
                };
                tcp_map.send_channel_message(channel_id, (msg + "\r\n").as_bytes()).await?;
                maybe_end_channel(tcp_map, channel_id).await;
                return Ok(());
            }
            // Forward to connected daemon
            debug!("dispatch_task: connect_key='{connect_key}', looking for session");
            match resolve_session_id(connect_map, connect_key).await {
                Ok(session_id) => {
                debug!("dispatch_task: found session_id={session_id}");
                // Strip command name from parameters for most commands
                let payload = match cmd {
                    HdcCommand::UnityExecute | HdcCommand::UnityReboot |
                    HdcCommand::UnityRemount | HdcCommand::UnityRunmode |
                    HdcCommand::UnityRootrun | HdcCommand::UnityHilog |
                    HdcCommand::UnityBugreportInit => {
                        if params.len() > 1 {
                            params[1..].join(" ").into_bytes()
                        } else {
                            vec![]
                        }
                    }
                    HdcCommand::AppUninstall => {
                        // Skip "uninstall" prefix, send only package name and options
                        if params.len() > 1 {
                            params[1..].join(" ").into_bytes()
                        } else {
                            vec![]
                        }
                    }
                    _ => params.join(" ").into_bytes(),
                };
                let msg = TaskMessage {
                    channel_id,
                    command: cmd,
                    payload,
                };
                let data = concat_pack(&msg);
                // Try TCP first, then fallback to USB
                if tcp_map.send_to_session(session_id, &data).await.is_err() {
                    if let Err(e) = usb_map.send_to_session(session_id, &data).await {
                        tcp_map.send_channel_message(channel_id, format!("[Fail]Send to daemon failed: {e}\r\n").as_bytes()).await?;
                    }
                }
                // Track this channel so we can close it if the USB device disconnects.
                tcp_map.associate_channel_with_session(channel_id, session_id).await;
                // For commands that the daemon does not close itself (e.g. uninstall),
                // collect responses and close the channel after a short idle timeout.
                if cmd == HdcCommand::AppUninstall {
                    let _ = collect_daemon_response_then_close(
                        tcp_map, usb_map, session_id, channel_id,
                    ).await;
                }
                // For other commands the daemon is expected to send KernelChannelClose
            }
            Err(e) => {
                tcp_map.send_channel_message(channel_id, format!("[Fail]{e}\r\n").as_bytes()).await?;
                maybe_end_channel(tcp_map, channel_id).await;
            }
        }
        }
    }
    Ok(())
}

// ============================================================================
// Forward list / remove helpers
// ============================================================================

async fn build_forward_list(forward_map: &ForwardMap, connect_key_filter: &str) -> String {
    let guard = forward_map.lock().await;
    let mut lines = Vec::new();
    for (_key, entry) in guard.iter() {
        if !connect_key_filter.is_empty() && connect_key_filter != "any" && entry.connect_key != connect_key_filter {
            continue;
        }
        let dir_str = match entry.direction {
            ForwardDirection::Forward => "[Forward]",
            ForwardDirection::Reverse => "[Reverse]",
        };
        lines.push(format!("{}    {}    {}", entry.connect_key, entry.task_string, dir_str));
    }
    lines.join("\r\n")
}

async fn remove_forward_entry(
    tcp_map: &TcpMap,
    usb_map: &UsbMap,
    forward_map: &ForwardMap,
    connect_key_filter: &str,
    request_channel_id: u32,
    spec: &str,
) -> io::Result<String> {
    let mut guard = forward_map.lock().await;

    if spec.is_empty() {
        // Remove all forward entries for this device
        let keys_to_remove: Vec<String> = guard
            .iter()
            .filter(|(_k, v)| {
                connect_key_filter.is_empty() || connect_key_filter == "any" || v.connect_key == connect_key_filter
            })
            .map(|(k, _v)| k.clone())
            .collect();
        let mut removed = 0;
        for key in keys_to_remove {
            if let Some(entry) = guard.remove(&key) {
                if let Some(handle) = entry.abort_handle {
                    handle.abort();
                    info!("Aborted forward listener for {key}");
                }
                // Send KernelChannelClose to daemon to clean up daemon-side resources
                let close_msg = TaskMessage {
                    channel_id: entry.channel_id,
                    command: HdcCommand::KernelChannelClose,
                    payload: vec![0],
                };
                let _ = send_to_session(tcp_map, usb_map, entry.session_id, &concat_pack(&close_msg)).await;
                removed += 1;
            }
        }
        return Ok(format!("Remove forward ruler success, removed {removed} rulers"));
    }

    // Try exact match first, then prefix match
    let mut found_key: Option<String> = None;
    if guard.contains_key(spec) {
        found_key = Some(spec.to_string());
    } else {
        for (key, entry) in guard.iter() {
            if key == spec || key.ends_with(&format!(" {}", spec)) || key.starts_with(&format!("{} ", spec)) {
                if connect_key_filter.is_empty() || connect_key_filter == "any" || entry.connect_key == connect_key_filter {
                    found_key = Some(key.clone());
                    break;
                }
            }
        }
    }

    if let Some(key) = found_key {
        if let Some(entry) = guard.remove(&key) {
            if let Some(handle) = entry.abort_handle {
                handle.abort();
                info!("Aborted forward listener for {key}");
            }
            let close_msg = TaskMessage {
                channel_id: entry.channel_id,
                command: HdcCommand::KernelChannelClose,
                payload: vec![0],
            };
            let _ = send_to_session(tcp_map, usb_map, entry.session_id, &concat_pack(&close_msg)).await;
            return Ok(format!("Remove forward ruler success, ruler:{key}"));
        }
    }

    Err(Error::new(ErrorKind::NotFound, format!("Remove forward ruler failed, ruler is not exist {spec}")))
}

fn make_tlv(tag: &str, val: &str) -> String {
    format!("{tag:<16}{:<16}{}", val.len(), val)
}

fn build_host_auth_buf() -> String {
    let mut buf = String::new();
    buf.push_str(&make_tlv("authtype", "1"));
    if let Ok(pubkey_info) = crate::auth::get_public_key_info() {
        buf.push_str(&make_tlv("pubkey", &pubkey_info));
    }
    let mut features = vec![FEATURE_HEARTBEAT];
    if std::env::var(ENV_ENCRYPT_CHANNEL).ok() == Some("1".to_string()) {
        features.push(FEATURE_ENCRYPT_TCP);
    }
    buf.push_str(&make_tlv("supportfeatures", &features.join(",")));
    buf
}

async fn recv_raw_hdc_frame(rd: &mut tokio::net::tcp::OwnedReadHalf) -> io::Result<Vec<u8>> {
    use hdc_protocol::serializer::{unpack_payload_head, HEAD_SIZE};
    let head = crate::transfer::tcp::read_frame(rd, HEAD_SIZE).await?;
    let payload_head = unpack_payload_head(&head)?;
    let expected_head_size = payload_head.head_size as usize;
    let expected_data_size = payload_head.data_size as usize;
    let protect = crate::transfer::tcp::read_frame(rd, expected_head_size).await?;
    let payload = crate::transfer::tcp::read_frame(rd, expected_data_size).await?;
    let mut frame = Vec::with_capacity(HEAD_SIZE + expected_head_size + expected_data_size);
    frame.extend_from_slice(&head);
    frame.extend_from_slice(&protect);
    frame.extend_from_slice(&payload);
    Ok(frame)
}

async fn recv_tcp_frame(
    rd: &mut tokio::net::tcp::OwnedReadHalf,
    cipher: Option<&Arc<tokio::sync::Mutex<PskCipher>>>,
) -> io::Result<Vec<u8>> {
    if let Some(cipher) = cipher {
        let len_bytes = crate::transfer::tcp::read_frame(rd, 4).await?;
        let len = u32::from_be_bytes([len_bytes[0], len_bytes[1], len_bytes[2], len_bytes[3]]) as usize;
        let ct = crate::transfer::tcp::read_frame(rd, len).await?;
        let mut cipher = cipher.lock().await;
        cipher.decrypt(&ct)
    } else {
        recv_raw_hdc_frame(rd).await
    }
}

async fn start_tcp_daemon_session(
    addr: &str,
    connect_map: &ConnectMap,
    tcp_map: &TcpMap,
    usb_map: &UsbMap,
    channel_id: u32,
) -> io::Result<()> {
    let _ = channel_id;
    // Official TargetConnect port validation: 1-5 digits, value in 1..=65535.
    let port_str = addr.rsplit_once(':').map(|(_, p)| p).unwrap_or("");
    if port_str.is_empty() || port_str.len() > 5 || !port_str.bytes().all(|b| b.is_ascii_digit()) {
        return Err(Error::new(ErrorKind::InvalidInput, "The port must be digit str"));
    }
    match port_str.parse::<u16>() {
        Ok(port) if port > 0 => {}
        _ => return Err(Error::new(ErrorKind::InvalidInput, "Port range incorrect")),
    }
    let stream = TcpStream::connect(addr).await?;
    let session_id = rand::random::<u32>();
    let (mut rd, wr) = stream.into_split();
    tcp_map.start_session(session_id, wr).await;

    let connect_key = addr.to_string();
    let version_with_hash = format!("{}{}", get_version(), "47d583e40754ffe6");
    let mut handshake = SessionHandShake {
        banner: HANDSHAKE_MESSAGE.to_string(),
        auth_type: AuthType::None as u8,
        session_id,
        connect_key: connect_key.clone(),
        buf: build_host_auth_buf(),
        version: version_with_hash,
    };

    let msg = TaskMessage {
        channel_id: 0,
        command: HdcCommand::KernelHandshake,
        payload: handshake.serialize(),
    };
    tcp_map.send_to_session(session_id, &concat_pack(&msg)).await?;

    // Authentication exchange loop, matching the USB handshake flow.
    let mut last_daemon_buf = String::new();
    let mut auth_ok = false;
    const MAX_AUTH_ATTEMPTS: u32 = 10;
    for attempt in 1..=MAX_AUTH_ATTEMPTS {
        let recv_timeout = if attempt == 2 {
            Duration::from_secs(60)
        } else {
            Duration::from_secs(10)
        };
        let daemon_resp = match tokio::time::timeout(
            recv_timeout,
            crate::transfer::tcp::unpack_task_message(&mut rd),
        )
        .await
        {
            Ok(Ok(r)) => r,
            Ok(Err(e)) => {
                let _ = tcp_map.end_session(session_id).await;
                return Err(e);
            }
            Err(_) => {
                let _ = tcp_map.end_session(session_id).await;
                return Err(Error::new(
                    ErrorKind::TimedOut,
                    "TCP authentication timeout",
                ));
            }
        };

        if daemon_resp.command != HdcCommand::KernelHandshake {
            warn!(
                "Unexpected command during TCP auth for {addr}: {:?}",
                daemon_resp.command
            );
            continue;
        }

        let daemon_hs = match SessionHandShake::deserialize(&daemon_resp.payload) {
            Ok(hs) => hs,
            Err(e) => {
                let _ = tcp_map.end_session(session_id).await;
                return Err(Error::new(
                    ErrorKind::InvalidData,
                    format!("Failed to deserialize daemon handshake: {e}"),
                ));
            }
        };
        last_daemon_buf = daemon_hs.buf.clone();

        match daemon_hs.auth_type {
            x if x == AuthType::Ok as u8 => {
                info!("TCP authentication successful for {addr}");
                auth_ok = true;
                break;
            }
            x if x == AuthType::Fail as u8 => {
                let _ = tcp_map.end_session(session_id).await;
                return Err(Error::new(
                    ErrorKind::PermissionDenied,
                    "TCP authentication rejected by daemon",
                ));
            }
            x if x == AUTH_TYPE_SSL_TLS_PSK => {
                if std::env::var(ENV_ENCRYPT_CHANNEL).ok() != Some("1".to_string()) {
                    let _ = tcp_map.end_session(session_id).await;
                    return Err(Error::new(
                        ErrorKind::PermissionDenied,
                        "Daemon requested encrypted TCP channel but OHOS_HDC_ENCRYPT_CHANNEL is not set to 1",
                    ));
                }
                let encrypted_psk = match base64::engine::general_purpose::STANDARD.decode(&daemon_hs.buf) {
                    Ok(v) => v,
                    Err(e) => {
                        let _ = tcp_map.end_session(session_id).await;
                        return Err(Error::new(
                            ErrorKind::InvalidData,
                            format!("Failed to base64-decode daemon PSK: {e}"),
                        ));
                    }
                };
                let psk_bytes = match crate::auth::decrypt_psk(&encrypted_psk) {
                    Ok(v) => v,
                    Err(e) => {
                        let _ = tcp_map.end_session(session_id).await;
                        return Err(Error::new(
                            ErrorKind::PermissionDenied,
                            format!("Failed to decrypt daemon PSK: {e}"),
                        ));
                    }
                };
                if psk_bytes.len() != 32 {
                    let _ = tcp_map.end_session(session_id).await;
                    return Err(Error::new(
                        ErrorKind::InvalidData,
                        format!("Daemon PSK length is {}, expected 32", psk_bytes.len()),
                    ));
                }
                let mut psk = [0u8; 32];
                psk.copy_from_slice(&psk_bytes);
                tcp_map.set_session_cipher(session_id, PskCipher::new(&psk, true)).await;

                // Reply with an empty PSK-ACK so the daemon enables encryption too.
                handshake.auth_type = AUTH_TYPE_SSL_TLS_PSK;
                handshake.buf = String::new();
                let msg = TaskMessage {
                    channel_id: 0,
                    command: HdcCommand::KernelHandshake,
                    payload: handshake.serialize(),
                };
                tcp_map.send_to_session(session_id, &concat_pack(&msg)).await?;
                info!("Encrypted TCP channel enabled for {addr}");
                auth_ok = true;
                break;
            }
            x if x == AuthType::Publickey as u8 => {
                let pubkey_info = match crate::auth::get_public_key_info() {
                    Ok(info) => info,
                    Err(e) => {
                        let _ = tcp_map.end_session(session_id).await;
                        return Err(Error::new(
                            ErrorKind::Other,
                            format!("Failed to get public key info: {e}"),
                        ));
                    }
                };
                handshake.auth_type = AuthType::Publickey as u8;
                handshake.buf = pubkey_info;
                let msg = TaskMessage {
                    channel_id: 0,
                    command: HdcCommand::KernelHandshake,
                    payload: handshake.serialize(),
                };
                tcp_map.send_to_session(session_id, &concat_pack(&msg)).await?;
                info!("Public key sent to daemon for {addr}; confirm network debugging authorization on the device if needed.");
            }
            x if x == AuthType::Signature as u8 => {
                let challenge = daemon_hs.buf;
                let signature = match crate::auth::rsa_sign_challenge(&challenge) {
                    Ok(sig) => sig,
                    Err(e) => {
                        let _ = tcp_map.end_session(session_id).await;
                        return Err(Error::new(
                            ErrorKind::Other,
                            format!("Failed to sign challenge: {e}"),
                        ));
                    }
                };
                handshake.auth_type = AuthType::Signature as u8;
                handshake.buf = signature;
                let msg = TaskMessage {
                    channel_id: 0,
                    command: HdcCommand::KernelHandshake,
                    payload: handshake.serialize(),
                };
                tcp_map.send_to_session(session_id, &concat_pack(&msg)).await?;
                info!("Signature sent to daemon for {addr}");
            }
            x if x == AuthType::Token as u8 => {
                let _ = tcp_map.end_session(session_id).await;
                return Err(Error::new(
                    ErrorKind::PermissionDenied,
                    "Token auth not supported",
                ));
            }
            other => {
                let _ = tcp_map.end_session(session_id).await;
                return Err(Error::new(
                    ErrorKind::InvalidData,
                    format!("Unknown auth type from daemon: {other}"),
                ));
            }
        }
    }

    if !auth_ok {
        let _ = tcp_map.end_session(session_id).await;
        return Err(Error::new(
            ErrorKind::PermissionDenied,
            "TCP authentication failed",
        ));
    }

    let dev_name = {
        let tlv_map = parse_tlv(&last_daemon_buf);
        tlv_map.get("devname").cloned().unwrap_or_default()
    };
    connect_map
        .put(
            connect_key.clone(),
            DaemonInfo {
                session_id,
                conn_type: ConnectType::Tcp,
                conn_status: ConnStatus::Connected,
                dev_name,
                version: String::new(),
            },
        )
        .await;

    // Start heartbeat task
    let heartbeat_disabled = std::env::var(ENV_SERVER_HEARTBEAT).ok() == Some("1".to_string());
    if !heartbeat_disabled {
        let tcp_map_heartbeat = tcp_map.clone();
        tokio::spawn(async move {
            let mut interval =
                tokio::time::interval(tokio::time::Duration::from_millis(HEARTBEAT_INTERVAL as u64));
            loop {
                interval.tick().await;
                let heartbeat = TaskMessage {
                    channel_id: 0,
                    command: HdcCommand::HeartbeatMsg,
                    payload: vec![],
                };
                let data = concat_pack(&heartbeat);
                if tcp_map_heartbeat
                    .send_to_session(session_id, &data)
                    .await
                    .is_err()
                {
                    break;
                }
            }
        });
    }

    // Forward daemon messages to the host client channels.
    let tcp_map_clone = tcp_map.clone();
    let connect_map_clone = connect_map.clone();
    let usb_map_clone = usb_map.clone();
    tokio::spawn(async move {
        loop {
            let cipher = tcp_map_clone.get_session_cipher(session_id).await;
            let frame = match recv_tcp_frame(&mut rd, cipher.as_ref()).await {
                Ok(f) => f,
                Err(e) => {
                    warn!("daemon read error: {e}");
                    connect_map_clone.remove(&connect_key).await;
                    let _ = tcp_map_clone.end_session(session_id).await;
                    break;
                }
            };
            let task = match hdc_protocol::serializer::unpack_task_message(&frame) {
                Ok(t) => t,
                Err(e) => {
                    warn!("daemon frame parse error: {e}");
                    continue;
                }
            };
            if task.command == HdcCommand::HeartbeatMsg {
                continue;
            }
            // Route file/app/forward responses to their registered handlers.
            if usb_map_clone.route_response(session_id, task.channel_id, task.clone()).await {
                continue;
            }
            if task.command == HdcCommand::KernelHandshake {
                if let Ok(daemon_hs) = SessionHandShake::deserialize(&task.payload) {
                    match daemon_hs.auth_type {
                        x if x == AuthType::Signature as u8 => {
                            if let Ok(signature) =
                                crate::auth::rsa_sign_challenge(&daemon_hs.buf)
                            {
                                let reply_hs = SessionHandShake {
                                    banner: HANDSHAKE_MESSAGE.to_string(),
                                    auth_type: AuthType::Signature as u8,
                                    session_id,
                                    connect_key: connect_key.clone(),
                                    buf: signature,
                                    version: format!("{}{}", get_version(), "47d583e40754ffe6"),
                                };
                                let reply_msg = TaskMessage {
                                    channel_id: 0,
                                    command: HdcCommand::KernelHandshake,
                                    payload: reply_hs.serialize(),
                                };
                                let _ = tcp_map_clone
                                    .send_to_session(session_id, &concat_pack(&reply_msg))
                                    .await;
                            }
                        }
                        x if x == AuthType::Ok as u8 => {}
                        _ => {}
                    }
                }
                continue;
            }
            if task.command == HdcCommand::KernelEcho {
                let payload = if task.payload.is_empty() {
                    &task.payload[..]
                } else {
                    &task.payload[1..]
                };
                let _ = tcp_map_clone.send_channel_message(task.channel_id, payload).await;
            } else if task.command == HdcCommand::KernelEchoRaw {
                let _ = tcp_map_clone
                    .send_channel_message(task.channel_id, &task.payload)
                    .await;
            } else if task.command == HdcCommand::KernelChannelClose {
                let _ = tcp_map_clone.end_channel(task.channel_id).await;
            } else if matches!(
                task.command,
                HdcCommand::FileInit | HdcCommand::FileCheck | HdcCommand::UnityBugreportInit
            ) {
                // Official 3.2.0f CheckHostCommandPermission: daemon-initiated file or
                // bugreport writes to the host are only valid while a matching client
                // request is active (routed above). Anything else is unauthorized.
                warn!(
                    "Drop unauthorized {:?} from daemon sid={} cid={}",
                    task.command, session_id, task.channel_id
                );
            } else {
                let _ = tcp_map_clone
                    .send_channel_message(task.channel_id, &task.payload)
                    .await;
            }
        }
    });

    Ok(())
}

// ============================================================================
// Server process management
// ============================================================================

pub async fn server_fork(addr: &str, log_level: usize, forward_listen_ip: &str) {
    let current_exe = match std::env::current_exe() {
        Ok(path) => path.display().to_string(),
        Err(err) => {
            error!("server_fork: {err}");
            return;
        }
    };

    let log_level_str = log_level.to_string();
    let mut args: Vec<&str> = vec!["-b", "-m", "-l", &log_level_str, "-s", addr];
    if forward_listen_ip != "127.0.0.1" && !forward_listen_ip.is_empty() {
        args.push("-e");
        args.push(forward_listen_ip);
    }

    #[cfg(target_os = "windows")]
    {
        use std::process::Stdio;
        use std::os::windows::process::CommandExt;
        let result = std::process::Command::new(&current_exe)
            .args(&args)
            .creation_flags(0x08000000) // CREATE_NO_WINDOW
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        match result {
            Ok(_) => {
                tokio::time::sleep(tokio::time::Duration::from_millis(1000)).await;
            }
            Err(e) => {
                warn!("server fork failed: {e}");
            }
        }
    }

    #[cfg(not(target_os = "windows"))]
    {
        let result = std::process::Command::new(&current_exe)
            .args(&args)
            .spawn();
        match result {
            Ok(_) => {
                tokio::time::sleep(tokio::time::Duration::from_millis(1000)).await;
            }
            Err(e) => {
                warn!("server fork failed: {e}");
            }
        }
    }
}

pub async fn server_kill() {
    let pids = get_process_pids().await;
    for pid in pids {
        if pid != std::process::id() {
            #[cfg(target_os = "windows")]
            {
                let _ = std::process::Command::new("taskkill")
                    .args(["/pid", &pid.to_string(), "/f"])
                    .output();
            }
            #[cfg(not(target_os = "windows"))]
            {
                let _ = std::process::Command::new("kill")
                    .args(["-9", &pid.to_string()])
                    .output();
            }
        }
    }
    println!("Kill server finish");
}

async fn get_process_pids() -> Vec<u32> {
    let mut pids = Vec::new();
    #[cfg(target_os = "windows")]
    {
        let output = std::process::Command::new("tasklist")
            .output();
        if let Ok(output) = output {
            let text = String::from_utf8_lossy(&output.stdout);
            for line in text.lines() {
                if line.contains("hdc.exe") || line.contains("hdc ") {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if parts.len() >= 2 {
                        if let Ok(pid) = parts[1].parse::<u32>() {
                            pids.push(pid);
                        }
                    }
                }
            }
        }
    }
    pids
}

// ============================================================================
// Interactive shell bridge (server side)
// ============================================================================

async fn run_server_shell_bridge(
    mut rd: tokio::net::tcp::OwnedReadHalf,
    mut wr: tokio::net::tcp::OwnedWriteHalf,
    connect_map: ConnectMap,
    usb_map: UsbMap,
    connect_key: String,
    channel_id: u32,
) {
    let session_id = match connect_map.get_session_id(&connect_key).await {
        Some(id) => id,
        None => {
            let _ = wr.write_all(b"[Fail]No device connected\r\n").await;
            let _ = wr.shutdown().await;
            return;
        }
    };

    // Register response channel for shell data from daemon
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<TaskMessage>();
    usb_map.register_response_channel(session_id, channel_id, tx).await;

    // Send initial shell command to daemon
    // Interactive shell uses ShellInit, not UnityExecute
    let shell_init = TaskMessage {
        channel_id,
        command: HdcCommand::ShellInit,
        payload: vec![],
    };
    let data = concat_pack(&shell_init);
    if let Err(e) = usb_map.send_to_session(session_id, &data).await {
        warn!("Failed to send shell init: {e}");
        let _ = wr.write_all(format!("[Fail]{e}\r\n").as_bytes()).await;
        usb_map.unregister_response_channel(session_id, channel_id).await;
        let _ = wr.shutdown().await;
        return;
    }

    // Spawn daemon reader: forward daemon shell data to TCP client
    let mut wr_for_daemon = wr;
    let daemon_reader = tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Some(task) => {
                    match task.command {
                        HdcCommand::ShellData | HdcCommand::KernelEcho | HdcCommand::KernelEchoRaw => {
                            // Send as length-prefixed raw data to client
                            let msg = [&(task.payload.len() as u32).to_be_bytes()[..], &task.payload].concat();
                            if wr_for_daemon.write_all(&msg).await.is_err() {
                                let _ = wr_for_daemon.shutdown().await;
                                break;
                            }
                        }
                        HdcCommand::KernelChannelClose => {
                            // Official server sends KernelChannelClose as HDC protocol message which
                            // the client ignores. Since we send length-prefixed raw data, forwarding
                            // the payload would corrupt client output. Just close the connection.
                            let _ = wr_for_daemon.shutdown().await;
                            break;
                        }
                        _ => {}
                    }
                }
                None => {
                    // All senders dropped (session ended / device disconnected).
                    // Shutdown the write half so the client gets EOF promptly.
                    let _ = wr_for_daemon.shutdown().await;
                    break;
                }
            }
        }
    });

    // Read from TCP client and forward to daemon as ShellData
    loop {
        match recv_channel_message(&mut rd).await {
            Ok(data) => {
                let shell_msg = TaskMessage {
                    channel_id,
                    command: HdcCommand::ShellData,
                    payload: data,
                };
                let packed = concat_pack(&shell_msg);
                if usb_map.send_to_session(session_id, &packed).await.is_err() {
                    break;
                }
            }
            Err(_) => break,
        }
    }

    let _ = daemon_reader.await;
    usb_map.unregister_response_channel(session_id, channel_id).await;
}

// ============================================================================
// File transfer (server side)
// ============================================================================

fn strip_quotes(s: &str) -> String {
    let s = s.trim();
    if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
        s[1..s.len()-1].to_string()
    } else {
        s.to_string()
    }
}

fn resolve_file_paths(params: &[String]) -> io::Result<(String, String)> {
    // params format: ["file", "send", "-cwd", "<dir>", "<local>", "<remote>"] or ["file", "send", "<local>", "<remote>"]
    if params.len() < 4 {
        return Err(Error::new(ErrorKind::InvalidInput, "Missing file path arguments"));
    }
    let mut idx = 2; // skip "file" and "send"
    let mut cwd = String::new();
    if params.len() > idx + 1 && params[idx] == "-cwd" {
        cwd = params[idx + 1].clone();
        idx += 2;
    }
    if params.len() < idx + 2 {
        return Err(Error::new(ErrorKind::InvalidInput, "Missing local or remote path"));
    }
    let local_raw = strip_quotes(&params[idx]);
    let remote_raw = strip_quotes(&params[idx + 1]);
    let local_path = if cwd.is_empty() {
        local_raw
    } else {
        format!("{}{}{}", cwd.trim_end_matches(std::path::MAIN_SEPARATOR), std::path::MAIN_SEPARATOR, local_raw)
    };
    Ok((local_path, remote_raw))
}

/// Send a TaskMessage via USB and wait for a specific response command.
async fn usb_send_and_wait(
    usb_map: &UsbMap,
    session_id: u32,
    rx: &mut tokio::sync::mpsc::UnboundedReceiver<TaskMessage>,
    msg: TaskMessage,
    expected_cmd: HdcCommand,
    timeout_secs: u64,
) -> io::Result<TaskMessage> {
    let data = concat_pack(&msg);
    usb_map.send_to_session(session_id, &data).await?;

    let timeout = std::time::Duration::from_secs(timeout_secs);
    match tokio::time::timeout(timeout, rx.recv()).await {
        Ok(Some(task)) => {
            if task.command == expected_cmd {
                Ok(task)
            } else {
                Err(Error::new(ErrorKind::InvalidData, format!("Expected {:?}, got {:?}", expected_cmd, task.command)))
            }
        }
        Ok(None) => Err(Error::new(ErrorKind::ConnectionAborted, "Response channel closed")),
        Err(_) => Err(Error::new(ErrorKind::TimedOut, "Timeout waiting for daemon response")),
    }
}

async fn handle_server_file_send(
    tcp_map: &TcpMap,
    usb_map: &UsbMap,
    session_id: u32,
    channel_id: u32,
    params: &[String],
) -> io::Result<()> {
    let (local_path, remote_path) = resolve_file_paths(params)?;

    let metadata = tokio::fs::metadata(&local_path).await.map_err(|e| {
        Error::new(ErrorKind::NotFound, format!("Local file not found: {e}"))
    })?;
    let file_size = metadata.len();
    info!("file send: local={local_path}, remote={remote_path}, size={file_size}");

    let local_filename = std::path::Path::new(&local_path)
        .file_name()
        .and_then(|s| s.to_str())
        .map(|s| s.to_string())
        .unwrap_or_default();

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<TaskMessage>();
    usb_map.register_response_channel(session_id, channel_id, tx).await;

    let result = async {
        // Step 1: Send KernelWakeupSlavetask to daemon (pre-creates slave task, no response)
        let wakeup = TaskMessage {
            channel_id,
            command: HdcCommand::KernelWakeupSlavetask,
            payload: vec![],
        };
        let data = concat_pack(&wakeup);
        send_to_session(tcp_map, usb_map, session_id, &data).await?;
        info!("WakeupSlavetask sent for file send");

        // Small delay to ensure daemon processes WakeupSlavetask before FileCheck
        tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;

        // Step 2: Send FileCheck with file info to daemon slave.
        // DevEco Studio may pass a directory as the remote path; if the daemon
        // reports "illegal operation on a directory", set optional_name to the
        // local filename (daemon uses path as directory + optional_name as file)
        // and retry once. KernelChannelClose from the first failed attempt may
        // arrive before the retry's FileBegin, so it is ignored during retry.
        let mut current_remote_path = remote_path.clone();
        let mut optional_name = String::new();
        let mut retried = false;
        let file_begin = 'file_begin_loop: loop {
            let file_check = TaskMessage {
                channel_id,
                command: HdcCommand::FileCheck,
                payload: {
                    let config = TransferConfig {
                        file_size,
                        atime: 0,
                        mtime: 0,
                        options: String::new(),
                        path: current_remote_path.clone(),
                        optional_name: optional_name.clone(),
                        update_if_new: false,
                        compress_type: 0,
                        hold_timestamp: false,
                        function_name: String::new(),
                        client_cwd: String::new(),
                        reserve1: String::new(),
                        reserve2: String::new(),
                    };
                    config.serialize()
                },
            };
            let data = concat_pack(&file_check);
            send_to_session(tcp_map, usb_map, session_id, &data).await?;

            let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(15);
            loop {
                match tokio::time::timeout_at(deadline, rx.recv()).await {
                    Ok(Some(task)) => {
                        if task.command == HdcCommand::FileBegin {
                            break 'file_begin_loop task;
                        }
                        let payload_str = String::from_utf8_lossy(&task.payload);
                        if payload_str.contains("illegal operation on a directory")
                            && !local_filename.is_empty()
                            && !retried
                        {
                            optional_name = local_filename.clone();
                            current_remote_path = current_remote_path.trim_end_matches(|c| c == '/' || c == '\\').to_string();
                            info!("Remote path is a directory, retrying with optional_name={optional_name}, path={current_remote_path}");
                            retried = true;
                            break; // send retry FileCheck
                        }
                        // During retry, ignore stale KernelChannelClose/WakeupSlavetask from the first attempt
                        if retried
                            && (task.command == HdcCommand::KernelChannelClose
                                || task.command == HdcCommand::KernelWakeupSlavetask)
                        {
                            info!("Ignoring {:?} pending from first FileCheck attempt", task.command);
                            continue;
                        }
                        return Err(Error::new(ErrorKind::InvalidData, format!("Expected FileBegin, got {:?}", task.command)));
                    }
                    Ok(None) => return Err(Error::new(ErrorKind::ConnectionAborted, "Response channel closed")),
                    Err(_) => return Err(Error::new(ErrorKind::TimedOut, "Timeout waiting for FileBegin")),
                }
            }
        };
        info!("FileBegin received, payload_len={}", file_begin.payload.len());

        // 按真实读取长度发送数据；空文件也发送一次零长度数据，让接收端进入写入完成流程。
        let chunk_size = MAX_SIZE_IOBUF - 64; // reserve 64 bytes for TransferPayload header
        let mut file = tokio::fs::File::open(&local_path).await?;
        let mut buf = vec![0u8; chunk_size];
        let mut offset: u64 = 0;
        loop {
            let n = file.read(&mut buf).await?;
            if n == 0 && offset > 0 {
                break;
            }
            let payload_head = TransferPayload {
                index: offset,
                compress_type: 0,
                compress_size: n as u32,
                uncompress_size: n as u32,
            };
            let head_bytes = payload_head.serialize();
            let mut payload = vec![0u8; 64];
            payload[..head_bytes.len().min(64)].copy_from_slice(&head_bytes[..head_bytes.len().min(64)]);
            payload.extend_from_slice(&buf[..n]);

            let file_data = TaskMessage {
                channel_id,
                command: HdcCommand::FileData,
                payload,
            };
            let data = concat_pack(&file_data);
            send_to_session(tcp_map, usb_map, session_id, &data).await?;
            offset += n as u64;
            if n == 0 { break; }
        }

        if offset != file_size {
            return Err(Error::new(ErrorKind::InvalidData, "local file size changed during transfer"));
        }
        // 官方接收端在异步写入、fsync和close完成后发FileFinish[1]，发送方才回[0]。
        // 旧实现提前发[1]会让daemon关闭尚未写完的文件，真机出现末尾22760字节被截断。
        // 不能靠延时掩盖竞态，也不能把任意KernelChannelClose当成传输成功。
        let mut completion = crate::send_completion::SendCompletion::default();
        let timeout = tokio::time::Duration::from_secs(30);
        let result = tokio::time::timeout(timeout, async {
            loop {
                match rx.recv().await {
                    Some(task) => {
                        match task.command {
                            HdcCommand::FileFinish => {
                                if let Some(flag) = completion.receiver_finish(&task.payload)? {
                                    let acknowledgement = TaskMessage {
                                        channel_id, command: HdcCommand::FileFinish, payload: vec![flag],
                                    };
                                    send_to_session(tcp_map, usb_map, session_id, &concat_pack(&acknowledgement)).await?;
                                    completion.acknowledged()?;
                                }
                            }
                            HdcCommand::KernelChannelClose => {
                                completion.channel_closed()?;
                                return Ok::<_, io::Error>("FileTransfer finish\r\n");
                            }
                            HdcCommand::KernelEcho if task.payload.first() == Some(&(MessageLevel::Fail as u8)) => {
                                return Err(Error::new(ErrorKind::Other, "daemon rejected file transfer"));
                            }
                            _ => {}
                        }
                    }
                    None => return Err(Error::new(ErrorKind::ConnectionAborted, "Response channel closed")),
                }
            }
        }).await;

        match result {
            Ok(Ok(msg)) => {
                tcp_map.send_channel_message(channel_id, msg.as_bytes()).await?;
            }
            Ok(Err(e)) => {
                tcp_map.send_channel_message(channel_id, format!("[Fail]FileTransfer failed: {e}\r\n").as_bytes()).await?;
            }
            Err(_) => {
                tcp_map.send_channel_message(channel_id, b"[Fail]FileTransfer timeout\r\n").await?;
            }
        }
        maybe_end_channel(tcp_map, channel_id).await;
        Ok(())
    }.await;

    usb_map.unregister_response_channel(session_id, channel_id).await;
    result
}

/// Mirrors official IsHostReceiveChildPath: every '/' or '\\' separated component
/// must not be "..", and the path must not contain an embedded NUL.
fn is_host_receive_child_path(path: &str) -> bool {
    if path.bytes().any(|b| b == 0) {
        return false;
    }
    !path.split(['/', '\\']).any(|component| component == "..")
}

async fn handle_server_file_recv(
    tcp_map: &TcpMap,
    usb_map: &UsbMap,
    session_id: u32,
    channel_id: u32,
    params: &[String],
) -> io::Result<()> {
    let (remote_path, local_path) = resolve_file_paths(params)?;
    info!("file recv: remote={remote_path}, local={local_path}");

    if let Some(parent) = std::path::Path::new(&local_path).parent() {
        tokio::fs::create_dir_all(parent).await.ok();
    }

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<TaskMessage>();
    usb_map.register_response_channel(session_id, channel_id, tx).await;

    let result = async {
        // Step 1: Send FileInit to daemon. Daemon becomes master (reader).
        // Payload format: "recv <remote> <local>" — daemon parses argv[0]=recv, argv[1]=remote, argv[2]=local
        let file_init = TaskMessage {
            channel_id,
            command: HdcCommand::FileInit,
            payload: format!("recv {remote_path} {local_path}").into_bytes(),
        };
        let data = concat_pack(&file_init);
        send_to_session(tcp_map, usb_map, session_id, &data).await?;
        info!("FileInit sent for file recv, daemon will become master");

        // Step 2: Wait for FileCheck from daemon (master), skipping WakeupSlavetask.
        // Daemon sends: WakeupSlavetask → BeginTransfer(open remote RO) → FileCheck(with TransferConfig)
        let file_check_msg = loop {
            match tokio::time::timeout(std::time::Duration::from_secs(15), rx.recv()).await {
                Ok(Some(task)) => match task.command {
                    HdcCommand::KernelWakeupSlavetask => {
                        debug!("Received WakeupSlavetask from daemon, ignoring");
                        continue;
                    }
                    HdcCommand::FileCheck => break task,
                    other => return Err(Error::new(
                        ErrorKind::InvalidData,
                        format!("Expected FileCheck, got {:?}", other)
                    )),
                },
                Ok(None) => return Err(Error::new(ErrorKind::ConnectionAborted, "Response channel closed")),
                Err(_) => return Err(Error::new(ErrorKind::TimedOut, "Timeout waiting for FileCheck")),
            }
        };
        debug!("FileCheck received from daemon, payload_len={}", file_check_msg.payload.len());

        let config = TransferConfig::deserialize(&file_check_msg.payload).ok();
        if let Some(cfg) = &config {
            // Official 3.2.0f host-receive permission check: optionalName must be a
            // child path (no '..' components, no embedded NUL). We always write to the
            // client-requested local_path and never to a daemon-supplied path, so this
            // is an anomaly check rather than a path-selection mechanism.
            if !is_host_receive_child_path(&cfg.optional_name) {
                warn!("file recv: daemon sent suspicious optionalName {:?}, continuing with client-specified path",
                    cfg.optional_name);
            }
        }
        let file_size = config.as_ref().map(|c| c.file_size).unwrap_or(0);
        info!("Remote file size: {file_size}");

        // Step 3: Open local file for writing, then send FileBegin to daemon.
        // This mirrors official slave behaviour: OnFileOpen(master=false) sends FileBegin.
        let mut file = tokio::fs::File::create(&local_path).await?;
        let file_begin = TaskMessage {
            channel_id,
            command: HdcCommand::FileBegin,
            payload: vec![], // empty payload is accepted by CheckFeatures
        };
        let data = concat_pack(&file_begin);
        send_to_session(tcp_map, usb_map, session_id, &data).await?;
        info!("FileBegin sent, daemon will start streaming data");

        // Step 4: Receive FileData until total_received >= file_size, then send FileFinish[1].
        // In official protocol, slave (host) sends FileFinish[1] first, master (daemon) replies FileFinish[0].
        let mut total_received: u64 = 0;
        let mut file_finish_sent = false;
        loop {
            match tokio::time::timeout(std::time::Duration::from_secs(60), rx.recv()).await {
                Ok(Some(task)) => match task.command {
                    HdcCommand::FileData => {
                        if task.payload.len() < 64 {
                            warn!("FileData payload too short: {}, skipping", task.payload.len());
                            continue;
                        }
                        let tp = match TransferPayload::deserialize(&task.payload[..64]) {
                            Ok(tp) => tp,
                            Err(e) => {
                                warn!("Failed to parse TransferPayload: {e}, writing raw payload");
                                file.write_all(&task.payload).await?;
                                total_received += task.payload.len() as u64;
                                continue;
                            }
                        };
                        let data_bytes = &task.payload[64..];
                        file.write_all(data_bytes).await?;
                        total_received += data_bytes.len() as u64;
                        debug!("FileData: index={}, compress_size={}, uncompress_size={}, total_received={}/{}",
                            tp.index, tp.compress_size, tp.uncompress_size, total_received, file_size);

                        // If all data received, slave sends FileFinish[1] first
                        if !file_finish_sent && total_received >= file_size {
                            debug!("All data received, sending FileFinish[1]");
                            let finish = TaskMessage {
                                channel_id,
                                command: HdcCommand::FileFinish,
                                payload: vec![1],
                            };
                            let data = concat_pack(&finish);
                            send_to_session(tcp_map, usb_map, session_id, &data).await?;
                            file_finish_sent = true;
                        }
                    }
                    HdcCommand::FileFinish => {
                        if !task.payload.is_empty() && task.payload[0] == 1 {
                            debug!("FileFinish[1] received from daemon (unexpected order), sending FileFinish[0] ack");
                            let ack = TaskMessage {
                                channel_id,
                                command: HdcCommand::FileFinish,
                                payload: vec![0],
                            };
                            let data = concat_pack(&ack);
                            send_to_session(tcp_map, usb_map, session_id, &data).await?;
                        } else {
                            debug!("FileFinish[0] received from daemon");
                        }
                        break;
                    }
                    HdcCommand::KernelEcho | HdcCommand::KernelEchoRaw => {
                        let msg = String::from_utf8_lossy(&task.payload);
                        tcp_map.send_channel_message(channel_id, msg.as_bytes()).await?;
                    }
                    HdcCommand::KernelChannelClose => {
                        debug!("KernelChannelClose during file recv");
                        break;
                    }
                    other => {
                        debug!("unexpected command during file recv: {:?}", other);
                    }
                },
                Ok(None) => return Err(Error::new(ErrorKind::ConnectionAborted, "Response channel closed")),
                Err(_) => return Err(Error::new(ErrorKind::TimedOut, "Timeout waiting for file data")),
            }
        }

        file.flush().await?;
        info!("file recv completed: {local_path}, total_received={total_received}");
        tcp_map.send_channel_message(channel_id, format!("FileTransfer finish, Size:{} bytes\r\n", total_received).as_bytes()).await?;
        maybe_end_channel(tcp_map, channel_id).await;
        Ok(())
    }.await;

    usb_map.unregister_response_channel(session_id, channel_id).await;
    result
}

async fn handle_server_app_install(
    tcp_map: &TcpMap,
    usb_map: &UsbMap,
    session_id: u32,
    channel_id: u32,
    params: &[String],
) -> io::Result<()> {
    // Official HdcHostApp::BeginInstall: args starting with '-' (except the -cwd
    // pair) are bm-install options passed through in TransferConfig.options;
    // every other arg is a package path (.hap/.hsp/.app or dir).
    let mut idx = 1;
    let mut client_cwd = String::new();
    let mut options = String::new();
    let mut packages: Vec<String> = Vec::new();
    while idx < params.len() {
        let arg = &params[idx];
        if arg == "-cwd" && idx + 1 < params.len() {
            client_cwd = params[idx + 1].clone();
            idx += 2;
            continue;
        }
        if arg.starts_with('-') {
            if !options.is_empty() {
                options.push(' ');
            }
            options.push_str(arg);
        } else {
            packages.push(arg.clone());
        }
        idx += 1;
    }
    if packages.is_empty() {
        return Err(Error::new(ErrorKind::InvalidInput, "[E006001] Not any installation package was found"));
    }

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<TaskMessage>();
    usb_map.register_response_channel(session_id, channel_id, tx).await;

    let mut cleanup_dirs: Vec<PathBuf> = Vec::new();
    let result = async {
        for package in &packages {
            let mut app_path = package.clone();
            if !client_cwd.is_empty() && !Path::new(&app_path).is_absolute() {
                app_path = format!("{client_cwd}{app_path}");
            }
            let is_app_pack = Path::new(&app_path)
                .extension()
                .and_then(|s| s.to_str())
                .map(|s| s.eq_ignore_ascii_case("app"))
                .unwrap_or(false);

            let hap_paths: Vec<PathBuf> = if is_app_pack {
                let temp_dir = std::env::temp_dir().join(format!("hdc_app_extract_{}", rand::random::<u32>()));
                std::fs::create_dir_all(&temp_dir)?;
                let haps = extract_haps_from_app(&app_path, &temp_dir)?;
                if haps.is_empty() {
                    return Err(Error::new(ErrorKind::InvalidData, "No .hap found in .app package"));
                }
                cleanup_dirs.push(temp_dir);
                haps
            } else {
                vec![PathBuf::from(&app_path)]
            };

            for hap_path in &hap_paths {
                install_single_hap(tcp_map, usb_map, session_id, channel_id, &mut rx, hap_path, &options).await?;
            }
        }

        maybe_end_channel(tcp_map, channel_id).await;
        Ok(())
    }.await;

    usb_map.unregister_response_channel(session_id, channel_id).await;
    for dir in cleanup_dirs {
        let _ = tokio::fs::remove_dir_all(dir).await;
    }
    result
}

fn extract_haps_from_app(app_path: &str, out_dir: &Path) -> io::Result<Vec<PathBuf>> {
    let file = std::fs::File::open(app_path)?;
    let mut archive = ZipArchive::new(file)
        .map_err(|e| Error::new(ErrorKind::InvalidData, format!("Failed to open .app as zip: {e}")))?;
    let mut haps = Vec::new();
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)
            .map_err(|e| Error::new(ErrorKind::InvalidData, format!("Zip entry error: {e}")))?;
        let name = entry.name().to_string();
        if name.to_ascii_lowercase().ends_with(".hap") {
            let file_name = Path::new(&name)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(&name);
            let out_path = out_dir.join(file_name);
            let mut out = std::fs::File::create(&out_path)?;
            std::io::copy(&mut entry, &mut out)
                .map_err(|e| Error::new(ErrorKind::InvalidData, format!("Extract failed: {e}")))?;
            haps.push(out_path);
        }
    }
    haps.sort();
    Ok(haps)
}

async fn install_single_hap(
    tcp_map: &TcpMap,
    usb_map: &UsbMap,
    session_id: u32,
    channel_id: u32,
    rx: &mut tokio::sync::mpsc::UnboundedReceiver<TaskMessage>,
    app_path: &Path,
    options: &str,
) -> io::Result<()> {
    let app_path_str = app_path.to_str().unwrap_or("app.hap");
    let file_name = app_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("app.hap");
    let remote_path = format!("/data/local/tmp/{}", file_name);
    info!("app install: local={app_path_str}, remote={remote_path}");

    let metadata = tokio::fs::metadata(app_path).await.map_err(|e| {
        Error::new(ErrorKind::NotFound, format!("App file not found: {e}"))
    })?;
    let file_size = metadata.len();

    // Step 1: Send AppInit to daemon (creates daemon slave task, no direct response).
    let app_init = TaskMessage {
        channel_id,
        command: HdcCommand::AppInit,
        payload: vec![],
    };
    let data = concat_pack(&app_init);
    send_to_session(tcp_map, usb_map, session_id, &data).await?;
    info!("AppInit sent, daemon will create slave task");

    // Step 2: Send AppCheck with file info to daemon slave.
    let app_check = TaskMessage {
        channel_id,
        command: HdcCommand::AppCheck,
        payload: {
            let config = TransferConfig {
                file_size,
                atime: 0,
                mtime: 0,
                options: options.to_string(),
                path: remote_path.clone(),
                optional_name: file_name.to_string(),
                update_if_new: false,
                compress_type: 0,
                hold_timestamp: false,
                function_name: "install".to_string(),
                client_cwd: String::new(),
                reserve1: String::new(),
                reserve2: String::new(),
            };
            config.serialize()
        },
    };
    let data = concat_pack(&app_check);
    send_to_session(tcp_map, usb_map, session_id, &data).await?;

    // Wait for AppBegin, skipping WakeupSlavetask
    loop {
        match tokio::time::timeout(std::time::Duration::from_secs(15), rx.recv()).await {
            Ok(Some(task)) => match task.command {
                HdcCommand::KernelWakeupSlavetask => {
                    debug!("Received WakeupSlavetask from daemon, ignoring");
                    continue;
                }
                HdcCommand::AppBegin => break,
                other => return Err(Error::new(
                    ErrorKind::InvalidData,
                    format!("Expected AppBegin, got {:?}", other)
                )),
            },
            Ok(None) => return Err(Error::new(ErrorKind::ConnectionAborted, "Response channel closed")),
            Err(_) => return Err(Error::new(ErrorKind::TimedOut, "Timeout waiting for AppBegin")),
        }
    }
    info!("AppBegin received, daemon ready to receive data");

    // Step 3: Stream app data with TransferPayload header (same as file send)
    let chunk_size = MAX_SIZE_IOBUF - 64;
    let mut file = tokio::fs::File::open(app_path).await?;
    let mut buf = vec![0u8; chunk_size];
    let mut offset: u64 = 0;
    loop {
        let n = file.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        let payload_head = TransferPayload {
            index: offset,
            compress_type: 0,
            compress_size: n as u32,
            uncompress_size: n as u32,
        };
        let head_bytes = payload_head.serialize();
        let mut payload = vec![0u8; 64];
        payload[..head_bytes.len().min(64)].copy_from_slice(&head_bytes[..head_bytes.len().min(64)]);
        payload.extend_from_slice(&buf[..n]);

        let app_data = TaskMessage {
            channel_id,
            command: HdcCommand::AppData,
            payload,
        };
        let data = concat_pack(&app_data);
        send_to_session(tcp_map, usb_map, session_id, &data).await?;
        offset += n as u64;
    }

    // Step 4: Wait for daemon install result (AppFinish).
    info!("App data sent, waiting for daemon install result...");
    let timeout = tokio::time::Duration::from_secs(120);
    let install_result = tokio::time::timeout(timeout, async {
        loop {
            match rx.recv().await {
                Some(task) => match task.command {
                    HdcCommand::AppFinish => {
                        if task.payload.len() >= 2 {
                            let mode = task.payload[0];
                            // Official daemon bug: exitStatus is actually a bool result (true=success=1),
                            // but AsyncInstallFinish checks `exitStatus == 0`. So payload[1]=0 means success.
                            let result = task.payload[1] == 0;
                            let msg = String::from_utf8_lossy(&task.payload[2..]);
                            return (mode, result, msg.to_string());
                        } else {
                            return (0, false, "Invalid AppFinish payload".to_string());
                        }
                    }
                    HdcCommand::KernelEcho | HdcCommand::KernelEchoRaw => {
                        let msg = String::from_utf8_lossy(&task.payload);
                        tcp_map.send_channel_message(channel_id, msg.as_bytes()).await.ok();
                    }
                    HdcCommand::KernelChannelClose => {
                        return (0, false, "Channel closed".to_string());
                    }
                    other => {
                        debug!("unexpected command during app install: {:?}", other);
                    }
                },
                None => return (0, false, "Response channel closed".to_string()),
            }
        }
    }).await;

    match install_result {
        Ok((mode, result, msg)) => {
            if result {
                tcp_map.send_channel_message(channel_id, format!("AppMod finish: {}\r\n", file_name).as_bytes()).await?;
            } else {
                let mode_str = match mode {
                    1 => "install",
                    2 => "uninstall",
                    3 => "sideload",
                    _ => "unknown",
                };
                return Err(Error::new(ErrorKind::Other, format!("[Fail]App {mode_str} failed: {msg}")));
            }
        }
        Err(_) => {
            return Err(Error::new(ErrorKind::TimedOut, "Timeout waiting for app install result"));
        }
    }

    Ok(())
}

// ============================================================================
// Flashd commands (update / flash / erase / format)
// ============================================================================

async fn handle_server_flashd(
    tcp_map: &TcpMap,
    usb_map: &UsbMap,
    session_id: u32,
    channel_id: u32,
    cmd: HdcCommand,
    params: &[String],
) -> io::Result<()> {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<TaskMessage>();
    usb_map.register_response_channel(session_id, channel_id, tx).await;

    let result = async {
        match cmd {
            HdcCommand::FlashdUpdateInit | HdcCommand::FlashdFlashInit => {
                let is_update = cmd == HdcCommand::FlashdUpdateInit;
                let (local_path, _force) = parse_flashd_file_args(params, is_update)?;
                validate_flashd_file(&local_path)?;
                let function_name = if is_update { "flashd_update" } else { "flashd_flash" };

                let metadata = tokio::fs::metadata(&local_path).await.map_err(|e| {
                    Error::new(ErrorKind::NotFound, format!("Flashd file not found: {e}"))
                })?;
                let file_size = metadata.len();
                let file_name = std::path::Path::new(&local_path)
                    .file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_default();

                // Send FlashdCheck with TransferConfig (official prefixes 8 zero bytes)
                let flashd_check = TaskMessage {
                    channel_id,
                    command: HdcCommand::FlashdCheck,
                    payload: {
                        let config = TransferConfig {
                            file_size,
                            atime: 0,
                            mtime: 0,
                            options: params.join(" "),
                            path: local_path.clone(),
                            optional_name: file_name.clone(),
                            update_if_new: false,
                            compress_type: 0,
                            hold_timestamp: false,
                            function_name: function_name.to_string(),
                            client_cwd: String::new(),
                            reserve1: String::new(),
                            reserve2: String::new(),
                        };
                        let mut buf = vec![0u8; 8];
                        buf.extend(config.serialize());
                        buf
                    },
                };
                send_to_session(tcp_map, usb_map, session_id, &concat_pack(&flashd_check)).await?;

                // Wait for FlashdBegin
                let _begin = wait_flashd_response(&mut rx, HdcCommand::FlashdBegin, channel_id, 15).await?;

                tcp_map.send_channel_message(channel_id, b"\rProcessing: 0%").await.ok();

                // Stream file data
                let chunk_size = MAX_SIZE_IOBUF - 64;
                let mut file = tokio::fs::File::open(&local_path).await?;
                let mut buf = vec![0u8; chunk_size];
                let mut offset: u64 = 0;
                let mut last_percent = 0u8;
                loop {
                    let n = file.read(&mut buf).await?;
                    if n == 0 {
                        break;
                    }
                    let payload_head = TransferPayload {
                        index: offset,
                        compress_type: 0,
                        compress_size: n as u32,
                        uncompress_size: n as u32,
                    };
                    let head_bytes = payload_head.serialize();
                    let mut payload = vec![0u8; 64];
                    payload[..head_bytes.len().min(64)].copy_from_slice(&head_bytes[..head_bytes.len().min(64)]);
                    payload.extend_from_slice(&buf[..n]);

                    let data_msg = TaskMessage {
                        channel_id,
                        command: HdcCommand::FlashdData,
                        payload,
                    };
                    send_to_session(tcp_map, usb_map, session_id, &concat_pack(&data_msg)).await?;
                    offset += n as u64;
                    let percent = if file_size > 0 {
                        ((offset as f64 / file_size as f64) * 100.0) as u8
                    } else {
                        100
                    };
                    if percent != last_percent {
                        let s = format!("\rProcessing: {}%", percent);
                        tcp_map.send_channel_message(channel_id, s.as_bytes()).await.ok();
                        last_percent = percent;
                    }
                }

                // Send FlashdFinish[1]
                let finish_out = TaskMessage {
                    channel_id,
                    command: HdcCommand::FlashdFinish,
                    payload: vec![1],
                };
                send_to_session(tcp_map, usb_map, session_id, &concat_pack(&finish_out)).await?;

                // Wait for daemon result
                wait_flashd_finish(&mut rx, channel_id, tcp_map).await?;
            }
            HdcCommand::FlashdErase | HdcCommand::FlashdFormat => {
                let msg = TaskMessage {
                    channel_id,
                    command: cmd,
                    payload: params.join(" ").into_bytes(),
                };
                send_to_session(tcp_map, usb_map, session_id, &concat_pack(&msg)).await?;
                wait_flashd_finish(&mut rx, channel_id, tcp_map).await?;
            }
            _ => {}
        }
        maybe_end_channel(tcp_map, channel_id).await;
        Ok(())
    }.await;

    usb_map.unregister_response_channel(session_id, channel_id).await;
    result
}

fn parse_flashd_file_args(params: &[String], is_update: bool) -> io::Result<(String, bool)> {
    if params.is_empty() {
        return Err(Error::new(ErrorKind::InvalidInput, "Missing flashd command"));
    }
    let args = &params[1..];
    let min_count = if is_update { 1usize } else { 2usize };
    let mut file_index = if is_update { 0usize } else { 1usize };
    let has_force = args.iter().any(|p| p == "-f");
    let count = if has_force { min_count + 1 } else { min_count };
    if args.len() != count || args.len() <= file_index {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            format!("Invalid flashd {} arguments", if is_update { "update" } else { "flash" }),
        ));
    }
    if has_force {
        file_index += 1;
    }
    Ok((args[file_index].clone(), has_force))
}

fn validate_flashd_file(path: &str) -> io::Result<()> {
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let valid = matches!(ext.as_str(), "img" | "bin" | "fd" | "cpio" | "zip");
    if !valid {
        return Err(Error::new(
            ErrorKind::InvalidInput,
            format!("Invalid flashd file type: {ext} (expected .img/.bin/.fd/.cpio/.zip)"),
        ));
    }
    Ok(())
}

async fn wait_flashd_response(
    rx: &mut tokio::sync::mpsc::UnboundedReceiver<TaskMessage>,
    expected: HdcCommand,
    channel_id: u32,
    secs: u64,
) -> io::Result<TaskMessage> {
    let deadline = tokio::time::Duration::from_secs(secs);
    loop {
        match tokio::time::timeout(deadline, rx.recv()).await {
            Ok(Some(task)) => {
                if task.channel_id != channel_id {
                    continue;
                }
                if task.command == HdcCommand::KernelWakeupSlavetask {
                    continue;
                }
                if task.command == expected {
                    return Ok(task);
                }
                return Err(Error::new(
                    ErrorKind::InvalidData,
                    format!("Expected {:?}, got {:?}", expected, task.command),
                ));
            }
            Ok(None) => return Err(Error::new(ErrorKind::ConnectionAborted, "Response channel closed")),
            Err(_) => return Err(Error::new(ErrorKind::TimedOut, format!("Timeout waiting for {:?}", expected))),
        }
    }
}

async fn wait_flashd_finish(
    rx: &mut tokio::sync::mpsc::UnboundedReceiver<TaskMessage>,
    channel_id: u32,
    tcp_map: &TcpMap,
) -> io::Result<()> {
    let timeout = tokio::time::Duration::from_secs(120);
    let res = tokio::time::timeout(timeout, async {
        loop {
            match rx.recv().await {
                Some(task) => {
                    if task.channel_id != channel_id {
                        continue;
                    }
                    match task.command {
                        HdcCommand::FlashdFinish => {
                            if task.payload.len() >= 2 {
                                let level = task.payload[1];
                                let info = String::from_utf8_lossy(&task.payload[2..]);
                                if level == MessageLevel::Ok as u8 {
                                    let out = if info.is_empty() {
                                        "\r\n".to_string()
                                    } else {
                                        format!("\r\n{}\r\n", info)
                                    };
                                    tcp_map.send_channel_message(channel_id, out.as_bytes()).await.ok();
                                    return Ok(());
                                } else {
                                    return Err(Error::new(
                                        ErrorKind::Other,
                                        format!("[Fail]Flashd failed: {info}"),
                                    ));
                                }
                            } else {
                                return Err(Error::new(ErrorKind::InvalidData, "Invalid FlashdFinish payload"));
                            }
                        }
                        HdcCommand::FlashdProgress => {
                            if !task.payload.is_empty() {
                                let pct = task.payload[0];
                                let s = format!("\rProcessing: {}%", pct);
                                tcp_map.send_channel_message(channel_id, s.as_bytes()).await.ok();
                            }
                        }
                        HdcCommand::KernelEcho | HdcCommand::KernelEchoRaw => {
                            let msg = String::from_utf8_lossy(&task.payload);
                            tcp_map.send_channel_message(channel_id, msg.as_bytes()).await.ok();
                        }
                        HdcCommand::KernelChannelClose => {
                            return Err(Error::new(ErrorKind::ConnectionAborted, "Channel closed"));
                        }
                        _ => {}
                    }
                }
                None => return Err(Error::new(ErrorKind::ConnectionAborted, "Response channel closed")),
            }
        }
    })
    .await;

    match res {
        Ok(Ok(())) => Ok(()),
        Ok(Err(e)) => Err(e),
        Err(_) => Err(Error::new(ErrorKind::TimedOut, "Timeout waiting for FlashdFinish")),
    }
}

// ============================================================================
// Port forwarding (server side)
// ============================================================================

fn parse_forward_port(spec: &str) -> io::Result<u16> {
    let parts: Vec<&str> = spec.splitn(2, ':').collect();
    if parts.len() != 2 {
        return Err(Error::new(ErrorKind::InvalidInput, "Invalid forward spec, expected proto:port"));
    }
    if parts[0] != "tcp" {
        return Err(Error::new(ErrorKind::InvalidInput, format!("Host only supports tcp: forward spec, got {}", parts[0])));
    }
    parts[1].parse::<u16>().map_err(|e| {
        Error::new(ErrorKind::InvalidInput, format!("Invalid port number: {e}"))
    })
}

async fn send_forward_check_result(
    usb_map: &UsbMap,
    session_id: u32,
    channel_id: u32,
    ctx_id: u32,
    ok: bool,
) -> io::Result<()> {
    let mut payload = vec![0u8; 5];
    payload[..4].copy_from_slice(&ctx_id.to_be_bytes());
    payload[4] = if ok { 1 } else { 0 };
    let msg = TaskMessage {
        channel_id,
        command: HdcCommand::ForwardCheckResult,
        payload,
    };
    usb_map.send_to_session(session_id, &concat_pack(&msg)).await
}

async fn handle_server_forward(
    tcp_map: &TcpMap,
    usb_map: &UsbMap,
    forward_map: &ForwardMap,
    connect_key: &str,
    session_id: u32,
    channel_id: u32,
    params: &[String],
) -> io::Result<()> {
    if params.len() < 3 {
        return Err(Error::new(ErrorKind::InvalidInput, "Invalid forward parameters. Usage: fport tcp:local tcp:remote|ark:pid@bundle|jdwp:pid"));
    }

    let local_spec = params[1].clone();
    let remote_spec = params[2].clone();

    if !local_spec.starts_with("tcp:") {
        return Err(Error::new(ErrorKind::InvalidInput, "Local forward node must be tcp:<port>"));
    }
    let local_port = parse_forward_port(&local_spec)?;

    // Official hdc supports several remote node schemas. We currently handle
    // tcp:<port> directly and pass through ark:... / jdwp:... / localabstract:...
    // to the daemon, which knows how to connect to the actual target.
    let remote_is_known = remote_spec.starts_with("tcp:")
        || remote_spec.starts_with("ark:")
        || remote_spec.starts_with("jdwp:")
        || remote_spec.starts_with("localabstract:")
        || remote_spec.starts_with("localreserved:")
        || remote_spec.starts_with("localfilesystem:")
        || remote_spec.starts_with("dev:");
    if !remote_is_known {
        return Err(Error::new(ErrorKind::InvalidInput,
            format!("Unsupported remote forward node: {remote_spec}")));
    }

    info!("Starting forward: local {local_spec} -> remote {remote_spec}");

    // Register response channel before sending the init command so we do not miss
    // the daemon's replies. The daemon may reply on the original channel or on the
    // forward context id, so register both.
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<TaskMessage>();
    usb_map.register_response_channel(session_id, channel_id, tx.clone()).await;

    // For ark:/jdwp: debugger forwards, this daemon build only works with the
    // ForwardInit flow plus a follow-up ForwardCheck. The textbook ForwardCheck-first
    // flow is ignored by the daemon for these specs, so skip it to avoid the 10 s
    // timeout that makes DevEco Studio give up.
    let is_debug_forward = remote_spec.starts_with("ark:") || remote_spec.starts_with("jdwp:");

    // Try the textbook (official C++) flow first for non-debug forwards: host sends
    // ForwardCheck, daemon sets up the remote endpoint and replies with
    // ForwardCheckResult. For ark:/jdwp: this is skipped and we use ForwardInit.
    let handshake = async {
        if is_debug_forward {
            return Err(Error::new(ErrorKind::Other,
                "Debug forward uses ForwardInit flow"));
        }

        let listen_ip = get_forward_listen_ip();
        let listener = TcpListener::bind(format!("{listen_ip}:{local_port}")).await
            .map_err(|e| Error::new(ErrorKind::AddrInUse,
                format!("Failed to bind {listen_ip}:{local_port}: {e}")))?;

        let ctx_id = rand::random::<u32>();
        // Register under the ctx_id as well; many daemon builds use the context id
        // as the message channel for forward-related replies.
        usb_map.register_response_channel(session_id, ctx_id, tx.clone()).await;

        let mut check_payload = vec![0u8; 4 + 8 + remote_spec.len() + 1];
        check_payload[..4].copy_from_slice(&ctx_id.to_be_bytes());
        check_payload[12..12 + remote_spec.len()].copy_from_slice(remote_spec.as_bytes());
        let check_msg = TaskMessage {
            channel_id,
            command: HdcCommand::ForwardCheck,
            payload: check_payload,
        };
        send_to_session(tcp_map, usb_map, session_id, &concat_pack(&check_msg)).await?;
        info!("ForwardCheck sent: ctx_id={ctx_id}, local={local_spec}, remote={remote_spec}");

        let result_timeout = tokio::time::Duration::from_secs(5);
        let ok = tokio::time::timeout(result_timeout, async {
            while let Some(task) = rx.recv().await {
                match task.command {
                    HdcCommand::ForwardCheckResult => {
                        if task.payload.len() >= 5 {
                            let resp_ctx_id = u32::from_be_bytes([
                                task.payload[0], task.payload[1], task.payload[2], task.payload[3],
                            ]);
                            let ok = task.payload[4] != 0;
                            if resp_ctx_id == ctx_id {
                                return Ok(ok);
                            }
                            warn!("ForwardCheckResult ctx_id mismatch: expected {ctx_id}, got {resp_ctx_id}");
                        }
                    }
                    HdcCommand::KernelChannelClose => {
                        return Err(Error::new(ErrorKind::ConnectionAborted,
                            "Channel closed by daemon during forward setup"));
                    }
                    _ => continue,
                }
            }
            Err(Error::new(ErrorKind::ConnectionAborted,
                "Response channel closed while waiting for ForwardCheckResult"))
        }).await.map_err(|_| Error::new(ErrorKind::TimedOut,
            "Timeout waiting for ForwardCheckResult from daemon"))??;

        if !ok {
            return Err(Error::new(ErrorKind::ConnectionRefused,
                "Daemon rejected ForwardCheck"));
        }
        info!("ForwardCheckResult OK: ctx_id={ctx_id}");

        // Daemon accepted; notify client and start accepting connections.
        tcp_map.send_channel_message(channel_id, b"Forwardport result:OK\r\n").await?;
        maybe_end_channel(tcp_map, channel_id).await;

        Ok((listener, ctx_id, remote_spec.clone()))
    }.await;

    let (listener, _ctx_id, daemon_remote_spec) = match handshake {
        Ok(v) => v,
        Err(e) if is_debug_forward => {
            info!("Using ForwardInit flow for debug forward: {remote_spec}");

            // ForwardInit flow plus follow-up ForwardCheck for ark:/jdwp:.
            let init_payload = format!("{} {}", local_spec, remote_spec).into_bytes();
            let init_msg = TaskMessage {
                channel_id,
                command: HdcCommand::ForwardInit,
                payload: init_payload,
            };
            send_to_session(tcp_map, usb_map, session_id, &concat_pack(&init_msg)).await?;
            info!("ForwardInit sent: {local_spec} {remote_spec}");

            let check_timeout = tokio::time::Duration::from_secs(10);
            let (ctx_id, daemon_remote_spec) = tokio::time::timeout(check_timeout, async {
                while let Some(task) = rx.recv().await {
                    match task.command {
                        HdcCommand::ForwardCheck => {
                            if task.payload.len() < 4 + 8 + 1 {
                                return Err(Error::new(ErrorKind::InvalidData,
                                    "ForwardCheck payload too short"));
                            }
                            let ctx_id = u32::from_be_bytes([
                                task.payload[0], task.payload[1], task.payload[2], task.payload[3],
                            ]);
                            let spec_start = 4 + 8;
                            let spec_end = task.payload[spec_start..]
                                .iter()
                                .position(|&b| b == 0)
                                .map(|pos| spec_start + pos)
                                .unwrap_or(task.payload.len());
                            let daemon_remote_spec =
                                String::from_utf8_lossy(&task.payload[spec_start..spec_end])
                                    .to_string();
                            return Ok((ctx_id, daemon_remote_spec));
                        }
                        HdcCommand::KernelChannelClose => {
                            return Err(Error::new(ErrorKind::ConnectionAborted,
                                "Channel closed by daemon during forward setup"));
                        }
                        _ => continue,
                    }
                }
                Err(Error::new(ErrorKind::ConnectionAborted,
                    "Response channel closed while waiting for ForwardCheck"))
            }).await.map_err(|_| Error::new(ErrorKind::TimedOut,
                "Timeout waiting for ForwardCheck from daemon"))??;

            info!("ForwardCheck received: ctx_id={ctx_id}, remote_spec={daemon_remote_spec}");

            let listen_ip = get_forward_listen_ip();
            let bind_result = TcpListener::bind(format!("{listen_ip}:{local_port}")).await;
            if let Err(ref e) = bind_result {
                let _ = send_forward_check_result(usb_map, session_id, channel_id, ctx_id, false).await;
                usb_map.unregister_response_channel(session_id, channel_id).await;
                return Err(Error::new(ErrorKind::AddrInUse,
                    format!("Failed to bind {listen_ip}:{local_port}: {e}")));
            }
            let listener = bind_result.unwrap();

            send_forward_check_result(usb_map, session_id, channel_id, ctx_id, true).await?;
            info!("ForwardCheckResult sent: ctx_id={ctx_id}");

            let success_timeout = tokio::time::Duration::from_secs(5);
            tokio::time::timeout(success_timeout, async {
                while let Some(task) = rx.recv().await {
                    match task.command {
                        HdcCommand::ForwardSuccess => {
                            info!("ForwardSuccess received: ctx_id={ctx_id}");
                            break;
                        }
                        HdcCommand::KernelEcho | HdcCommand::KernelEchoRaw => {
                            let msg = String::from_utf8_lossy(&task.payload);
                            if msg.contains("Forwardport result") {
                                break;
                            }
                        }
                        _ => continue,
                    }
                }
            }).await.ok();

            // Follow-up ForwardCheck to trigger SetupArkPoint/SetupJdwpPoint on the
            // existing forward task. This daemon build creates a TCP master for
            // ForwardInit even for ark:/jdwp:; the follow-up ForwardCheck converts it
            // to a real debugger channel.
            let mut check_payload = vec![0u8; 4 + 8 + daemon_remote_spec.len() + 1];
            check_payload[..4].copy_from_slice(&ctx_id.to_be_bytes());
            check_payload[12..12 + daemon_remote_spec.len()].copy_from_slice(daemon_remote_spec.as_bytes());
            let check_msg = TaskMessage {
                channel_id,
                command: HdcCommand::ForwardCheck,
                payload: check_payload,
            };
            send_to_session(tcp_map, usb_map, session_id, &concat_pack(&check_msg)).await?;
            info!("Follow-up ForwardCheck sent: ctx_id={ctx_id}, remote={daemon_remote_spec}");

            let check2_timeout = tokio::time::Duration::from_secs(5);
            let result = tokio::time::timeout(check2_timeout, async {
                while let Some(task) = rx.recv().await {
                    match task.command {
                        HdcCommand::ForwardCheckResult => {
                            if task.payload.len() >= 5 {
                                let resp_ctx_id = u32::from_be_bytes([
                                    task.payload[0], task.payload[1], task.payload[2], task.payload[3],
                                ]);
                                let ok = task.payload[4] != 0;
                                if resp_ctx_id == ctx_id {
                                    return Some(ok);
                                }
                            }
                        }
                        HdcCommand::KernelChannelClose => return Some(false),
                        _ => continue,
                    }
                }
                None
            }).await;
            match result {
                Ok(Some(true)) => info!("Follow-up ForwardCheckResult OK: ctx_id={ctx_id}"),
                Ok(Some(false)) => warn!("Follow-up ForwardCheckResult rejected: ctx_id={ctx_id}"),
                _ => warn!("Follow-up ForwardCheck timed out: ctx_id={ctx_id}"),
            }

            tcp_map.send_channel_message(channel_id, b"Forwardport result:OK\r\n").await?;
            maybe_end_channel(tcp_map, channel_id).await;

            (listener, ctx_id, daemon_remote_spec)
        }
        Err(e) => {
            warn!("ForwardCheck flow failed ({e}); falling back to ForwardInit flow");

            // Fallback: some device daemon builds expect the host to send ForwardInit
            // and reply to the daemon's ForwardCheck. This works for plain tcp:
            // forwards but cannot set up an ark: debugger socketpair.
            let init_payload = format!("{} {}", local_spec, remote_spec).into_bytes();
            let init_msg = TaskMessage {
                channel_id,
                command: HdcCommand::ForwardInit,
                payload: init_payload,
            };
            send_to_session(tcp_map, usb_map, session_id, &concat_pack(&init_msg)).await?;
            info!("ForwardInit sent (fallback): {local_spec} {remote_spec}");

            let check_timeout = tokio::time::Duration::from_secs(10);
            let (ctx_id, daemon_remote_spec) = tokio::time::timeout(check_timeout, async {
                while let Some(task) = rx.recv().await {
                    match task.command {
                        HdcCommand::ForwardCheck => {
                            if task.payload.len() < 4 + 8 + 1 {
                                return Err(Error::new(ErrorKind::InvalidData,
                                    "ForwardCheck payload too short"));
                            }
                            let ctx_id = u32::from_be_bytes([
                                task.payload[0], task.payload[1], task.payload[2], task.payload[3],
                            ]);
                            let spec_start = 4 + 8;
                            let spec_end = task.payload[spec_start..]
                                .iter()
                                .position(|&b| b == 0)
                                .map(|pos| spec_start + pos)
                                .unwrap_or(task.payload.len());
                            let daemon_remote_spec =
                                String::from_utf8_lossy(&task.payload[spec_start..spec_end])
                                    .to_string();
                            return Ok((ctx_id, daemon_remote_spec));
                        }
                        HdcCommand::KernelChannelClose => {
                            return Err(Error::new(ErrorKind::ConnectionAborted,
                                "Channel closed by daemon during forward setup"));
                        }
                        _ => continue,
                    }
                }
                Err(Error::new(ErrorKind::ConnectionAborted,
                    "Response channel closed while waiting for ForwardCheck"))
            }).await.map_err(|_| Error::new(ErrorKind::TimedOut,
                "Timeout waiting for ForwardCheck from daemon"))??;

            info!("ForwardCheck received (fallback): ctx_id={ctx_id}, remote_spec={daemon_remote_spec}");

            let listen_ip = get_forward_listen_ip();
            let bind_result = TcpListener::bind(format!("{listen_ip}:{local_port}")).await;
            if let Err(ref e) = bind_result {
                let _ = send_forward_check_result(usb_map, session_id, channel_id, ctx_id, false).await;
                usb_map.unregister_response_channel(session_id, channel_id).await;
                return Err(Error::new(ErrorKind::AddrInUse,
                    format!("Failed to bind {listen_ip}:{local_port}: {e}")));
            }
            let listener = bind_result.unwrap();

            send_forward_check_result(usb_map, session_id, channel_id, ctx_id, true).await?;
            info!("ForwardCheckResult sent (fallback): ctx_id={ctx_id}");

            let success_timeout = tokio::time::Duration::from_secs(5);
            tokio::time::timeout(success_timeout, async {
                while let Some(task) = rx.recv().await {
                    match task.command {
                        HdcCommand::ForwardSuccess => {
                            info!("ForwardSuccess received (fallback): ctx_id={ctx_id}");
                            break;
                        }
                        HdcCommand::KernelEcho | HdcCommand::KernelEchoRaw => {
                            let msg = String::from_utf8_lossy(&task.payload);
                            if msg.contains("Forwardport result") {
                                break;
                            }
                        }
                        _ => continue,
                    }
                }
            }).await.ok();

            tcp_map.send_channel_message(channel_id, b"Forwardport result:OK\r\n").await?;
            maybe_end_channel(tcp_map, channel_id).await;

            (listener, ctx_id, daemon_remote_spec)
        }
    };

    // Step 5: Start central dispatcher and accept loop.
    // The central dispatcher routes per-connection ForwardData / ForwardActiveMaster /
    // ForwardFreeContext messages using the connection id (first 4 bytes of payload).
    let forward_conns: Arc<Mutex<HashMap<u32, tokio::sync::mpsc::UnboundedSender<Vec<u8>>>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let forward_conns_disp = forward_conns.clone();

    tokio::spawn(async move {
        while let Some(task) = rx.recv().await {
            match task.command {
                HdcCommand::ForwardData
                | HdcCommand::ForwardActiveMaster
                | HdcCommand::ForwardFreeContext => {
                    if task.payload.len() >= 4 {
                        let forward_id = u32::from_be_bytes([
                            task.payload[0], task.payload[1], task.payload[2], task.payload[3],
                        ]);
                        match task.command {
                            HdcCommand::ForwardData => {
                                let data = task.payload[4..].to_vec();
                                if let Some(sender) = forward_conns_disp.lock().await.get(&forward_id) {
                                    let _ = sender.send(data);
                                }
                            }
                            HdcCommand::ForwardActiveMaster => {
                                // Empty vec signals activation.
                                if let Some(sender) = forward_conns_disp.lock().await.get(&forward_id) {
                                    let _ = sender.send(vec![]);
                                }
                            }
                            HdcCommand::ForwardFreeContext => {
                                forward_conns_disp.lock().await.remove(&forward_id);
                            }
                            _ => {}
                        }
                    }
                }
                _ => {}
            }
        }
    });

    let usb_map_clone = usb_map.clone();
    let remote_spec_clone = daemon_remote_spec.clone();

    let listener_handle = tokio::spawn(async move {
        loop {
            match listener.accept().await {
                Ok((stream, addr)) => {
                    info!("Forward connection from {addr} -> {remote_spec_clone}");
                    let usb_map_inner = usb_map_clone.clone();
                    let forward_conns_inner = forward_conns.clone();
                    tokio::spawn(run_forward_bridge(
                        stream, usb_map_inner, session_id, channel_id,
                        remote_spec_clone.clone(), forward_conns_inner,
                    ));
                }
                Err(e) => {
                    error!("Forward accept failed: {e}");
                    break;
                }
            }
        }
    });

    // Register forward entry
    let task_string = format!("{} {}", local_spec, remote_spec);
    let entry = ForwardEntry {
        channel_id,
        session_id,
        connect_key: connect_key.to_string(),
        direction: ForwardDirection::Forward,
        task_string: task_string.clone(),
        abort_handle: Some(listener_handle.abort_handle()),
    };
    forward_map.lock().await.insert(task_string, entry);

    Ok(())
}

async fn run_forward_bridge(
    stream: TcpStream,
    usb_map: UsbMap,
    session_id: u32,
    channel_id: u32,
    remote_spec: String,
    forward_conns: Arc<Mutex<HashMap<u32, tokio::sync::mpsc::UnboundedSender<Vec<u8>>>>>,
) {
    let forward_id = rand::random::<u32>();
    let (conn_tx, mut conn_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
    forward_conns.lock().await.insert(forward_id, conn_tx);

    let (mut local_rd, mut local_wr) = stream.into_split();

    // Step 1: Send ForwardActiveSlave to daemon
    // Payload format: 4B forward_id + 8B param_bits (zeros) + remote_spec + null
    let mut active_payload = vec![0u8; 4 + 8 + remote_spec.len() + 1];
    active_payload[..4].copy_from_slice(&forward_id.to_be_bytes());
    active_payload[12..12 + remote_spec.len()].copy_from_slice(remote_spec.as_bytes());
    let active_slave = TaskMessage {
        channel_id,
        command: HdcCommand::ForwardActiveSlave,
        payload: active_payload,
    };
    let data = concat_pack(&active_slave);
    if let Err(e) = usb_map.send_to_session(session_id, &data).await {
        warn!("Failed to send ForwardActiveSlave for forward_id={forward_id}: {e}");
        forward_conns.lock().await.remove(&forward_id);
        return;
    }
    info!("ForwardActiveSlave sent for forward_id={forward_id}");

    // Step 2: Wait for ForwardActiveMaster from daemon (empty vec = activation signal)
    let active = tokio::time::timeout(tokio::time::Duration::from_secs(10), async {
        while let Some(data) = conn_rx.recv().await {
            if data.is_empty() {
                return true;
            }
        }
        false
    }).await;

    if active != Ok(true) {
        warn!("ForwardActiveMaster timeout or failed for forward_id={forward_id}");
        forward_conns.lock().await.remove(&forward_id);
        return;
    }
    info!("ForwardActiveMaster received for forward_id={forward_id}, starting data bridge");

    // Step 3: Bidirectional data bridge
    let usb_map_for_send = usb_map.clone();
    let forward_id_for_send = forward_id;
    let tcp_to_usb = tokio::spawn(async move {
        let mut buf = vec![0u8; 4096];
        loop {
            match local_rd.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    let mut payload = vec![0u8; 4 + n];
                    payload[..4].copy_from_slice(&forward_id_for_send.to_be_bytes());
                    payload[4..].copy_from_slice(&buf[..n]);
                    let msg = TaskMessage {
                        channel_id,
                        command: HdcCommand::ForwardData,
                        payload,
                    };
                    let data = concat_pack(&msg);
                    if usb_map_for_send.send_to_session(session_id, &data).await.is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    let usb_to_tcp = tokio::spawn(async move {
        while let Some(data) = conn_rx.recv().await {
            if data.is_empty() {
                continue; // skip stray activation signals
            }
            if local_wr.write_all(&data).await.is_err() {
                break;
            }
        }
    });

    let _ = tokio::join!(tcp_to_usb, usb_to_tcp);
    info!("Forward bridge closed for forward_id={forward_id}");
    forward_conns.lock().await.remove(&forward_id);

    // Notify daemon to free context
    let free_payload = forward_id.to_be_bytes().to_vec();
    let free_msg = TaskMessage {
        channel_id,
        command: HdcCommand::ForwardFreeContext,
        payload: free_payload,
    };
    let data = concat_pack(&free_msg);
    let _ = usb_map.send_to_session(session_id, &data).await;
}

// ============================================================================
// Reverse port forwarding (server side)
// ============================================================================

async fn handle_server_rport(
    tcp_map: &TcpMap,
    usb_map: &UsbMap,
    forward_map: &ForwardMap,
    connect_key: &str,
    session_id: u32,
    channel_id: u32,
    params: &[String],
) -> io::Result<()> {
    if params.len() < 3 {
        return Err(Error::new(ErrorKind::InvalidInput, "Invalid rport parameters. Usage: rport tcp:remote tcp:local"));
    }

    let remote_spec = params[1].clone(); // daemon listens here (e.g. "tcp:8080")
    let local_spec = params[2].clone();  // host connects here (e.g. "tcp:18080")

    // Verify local_spec is a valid tcp port (host side must be tcp)
    let _local_port = parse_forward_port(&local_spec)?;

    info!("Starting rport: remote {remote_spec} -> local {local_spec}, channel_id={channel_id}");

    // Step 1: Send ForwardInit to daemon so daemon becomes master (listens on remote)
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<TaskMessage>();
    usb_map.register_response_channel(session_id, channel_id, tx).await;

    let result = async {
        // rport protocol:
        // 1. Host sends ForwardInit to daemon, daemon creates master context listening on remote_spec
        // 2. Daemon sends ForwardCheck to host (verify local is reachable)
        // 3. Host replies ForwardCheckResult
        // 4. On remote connection: daemon sends ForwardActiveSlave, host connects to local,
        //    host replies ForwardActiveMaster, then ForwardData flows
        let init_payload = format!("{} {}", remote_spec, local_spec);
        let forward_init = TaskMessage {
            channel_id,
            command: HdcCommand::ForwardInit,
            payload: init_payload.into_bytes(),
        };
        let data = concat_pack(&forward_init);
        send_to_session(tcp_map, usb_map, session_id, &data).await?;
        info!("ForwardInit sent for rport, remote={remote_spec} local={local_spec}");

        // rport flow: daemon sends ForwardCheck -> host replies ForwardCheckResult
        // -> daemon sends ForwardSuccess as confirmation
        let check_timeout = tokio::time::Duration::from_secs(10);
        let setup_result = tokio::time::timeout(check_timeout, async {
            while let Some(task) = rx.recv().await {
                match task.command {
                    HdcCommand::ForwardCheck => {
                        // Daemon asks host to verify local port is reachable
                        if task.payload.len() >= 4 + 8 + 1 {
                            let forward_id = u32::from_be_bytes([
                                task.payload[0], task.payload[1], task.payload[2], task.payload[3]
                            ]);
                            let local_spec = String::from_utf8_lossy(&task.payload[12..])
                                .trim_end_matches('\0')
                                .to_string();
                            info!("Rport ForwardCheck received, forward_id={forward_id}, local_spec={local_spec}");
                            let flag: u8 = match parse_forward_port(&local_spec) {
                                Ok(port) => {
                                    match tokio::net::TcpStream::connect(format!("127.0.0.1:{port}")).await {
                                        Ok(_) => 1,
                                        Err(e) => {
                                            warn!("Rport ForwardCheck: local port {port} not reachable: {e}");
                                            0
                                        }
                                    }
                                }
                                Err(e) => {
                                    warn!("Rport ForwardCheck: invalid local spec '{local_spec}': {e}");
                                    0
                                }
                            };
                            // Send ForwardCheckResult: 4B forward_id + 1B flag
                            let mut result_payload = vec![0u8; 5];
                            result_payload[..4].copy_from_slice(&forward_id.to_be_bytes());
                            result_payload[4] = flag;
                            let result_msg = TaskMessage {
                                channel_id,
                                command: HdcCommand::ForwardCheckResult,
                                payload: result_payload,
                            };
                            let _ = send_to_session(tcp_map, usb_map, session_id, &concat_pack(&result_msg)).await;
                        }
                        continue;
                    }
                    HdcCommand::ForwardSuccess => {
                        info!("ForwardSuccess received for rport");
                        return Ok(());
                    }
                    HdcCommand::KernelWakeupSlavetask => {
                        debug!("WakeupSlavetask during rport setup, ignoring");
                        continue;
                    }
                    HdcCommand::KernelEcho | HdcCommand::KernelEchoRaw => {
                        let msg = String::from_utf8_lossy(&task.payload);
                        tcp_map.send_channel_message(channel_id, msg.as_bytes()).await.ok();
                    }
                    HdcCommand::KernelChannelClose => {
                        return Err(Error::new(ErrorKind::ConnectionAborted, "Channel closed by daemon"));
                    }
                    _ => continue,
                }
            }
            Err(Error::new(ErrorKind::ConnectionAborted, "Response channel closed"))
        }).await;

        match setup_result {
            Ok(Ok(())) => {}
            Ok(Err(e)) => return Err(e),
            Err(_) => return Err(Error::new(ErrorKind::TimedOut, "Timeout waiting for ForwardSuccess")),
        }

        tcp_map.send_channel_message(channel_id, b"Forwardport result:OK\r\n").await?;
        maybe_end_channel(tcp_map, channel_id).await;
        Ok(())
    }.await;

    if result.is_err() {
        usb_map.unregister_response_channel(session_id, channel_id).await;
        return result;
    }

    // Register rport entry
    let task_string = format!("{} {}", remote_spec, local_spec);
    let entry = ForwardEntry {
        channel_id,
        session_id,
        connect_key: connect_key.to_string(),
        direction: ForwardDirection::Reverse,
        task_string: task_string.clone(),
        abort_handle: None, // rport listener is on daemon side, host just connects
    };
    forward_map.lock().await.insert(task_string, entry);

    // Step 2: Start central dispatcher
    // Central dispatcher receives ForwardActiveSlave (daemon connected), ForwardData, ForwardFreeContext
    let forward_conns: Arc<Mutex<HashMap<u32, tokio::sync::mpsc::UnboundedSender<Vec<u8>>>>> = Arc::new(Mutex::new(HashMap::new()));
    let forward_conns_disp = forward_conns.clone();
    let usb_map_disp = usb_map.clone();
    let tcp_map_disp = tcp_map.clone();

    tokio::spawn(async move {
        while let Some(task) = rx.recv().await {
            match task.command {
                HdcCommand::ForwardCheck => {
                    // Daemon sends ForwardCheck to verify local port is reachable
                    // Payload: 4B forward_id + 8B param_bits + local_spec + null
                    if task.payload.len() >= 4 + 8 + 1 {
                        let forward_id = u32::from_be_bytes([
                            task.payload[0], task.payload[1], task.payload[2], task.payload[3]
                        ]);
                        let local_spec = String::from_utf8_lossy(&task.payload[12..])
                            .trim_end_matches('\0')
                            .to_string();
                        info!("Rport ForwardCheck received, forward_id={forward_id}, local_spec={local_spec}");
                        // Try to connect to local port to verify it's reachable
                        let flag: u8 = match parse_forward_port(&local_spec) {
                            Ok(port) => {
                                match tokio::net::TcpStream::connect(format!("127.0.0.1:{port}")).await {
                                    Ok(_) => 1,
                                    Err(e) => {
                                        warn!("Rport ForwardCheck: local port {port} not reachable: {e}");
                                        0
                                    }
                                }
                            }
                            Err(e) => {
                                warn!("Rport ForwardCheck: invalid local spec '{local_spec}': {e}");
                                0
                            }
                        };
                        // Send ForwardCheckResult: 4B forward_id + 1B flag
                        let mut result_payload = vec![0u8; 5];
                        result_payload[..4].copy_from_slice(&forward_id.to_be_bytes());
                        result_payload[4] = flag;
                        let result_msg = TaskMessage {
                            channel_id,
                            command: HdcCommand::ForwardCheckResult,
                            payload: result_payload,
                        };
                        let _ = send_to_session(&tcp_map_disp, &usb_map_disp, session_id, &concat_pack(&result_msg)).await;
                    }
                }
                HdcCommand::ForwardActiveSlave => {
                    // Daemon has accepted a remote connection, we need to connect to local port
                    // Payload: 4B forward_id + 8B param_bits + local_spec + null
                    if task.payload.len() >= 4 + 8 + 1 {
                        let forward_id = u32::from_be_bytes([
                            task.payload[0], task.payload[1], task.payload[2], task.payload[3]
                        ]);
                        // Extract local_spec from payload[12..] (null-terminated string)
                        let local_spec = String::from_utf8_lossy(&task.payload[12..])
                            .trim_end_matches('\0')
                            .to_string();
                        info!("Rport ForwardActiveSlave received, forward_id={forward_id}, local_spec={local_spec}");
                        let usb_map_inner = usb_map_disp.clone();
                        let tcp_map_inner = tcp_map_disp.clone();
                        let forward_conns_inner = forward_conns_disp.clone();
                        tokio::spawn(run_rport_bridge(
                            forward_id, local_spec, tcp_map_inner, usb_map_inner, session_id, channel_id, forward_conns_inner
                        ));
                    }
                }
                HdcCommand::ForwardData | HdcCommand::ForwardFreeContext => {
                    if task.payload.len() >= 4 {
                        let forward_id = u32::from_be_bytes([
                            task.payload[0], task.payload[1], task.payload[2], task.payload[3]
                        ]);
                        match task.command {
                            HdcCommand::ForwardData => {
                                let data = task.payload[4..].to_vec();
                                if let Some(sender) = forward_conns_disp.lock().await.get(&forward_id) {
                                    let _ = sender.send(data);
                                }
                            }
                            HdcCommand::ForwardFreeContext => {
                                forward_conns_disp.lock().await.remove(&forward_id);
                            }
                            _ => {}
                        }
                    }
                }
                _ => {}
            }
        }
    });

    Ok(())
}

async fn run_rport_bridge(
    forward_id: u32,
    local_spec: String,
    tcp_map: TcpMap,
    usb_map: UsbMap,
    session_id: u32,
    channel_id: u32,
    forward_conns: Arc<Mutex<HashMap<u32, tokio::sync::mpsc::UnboundedSender<Vec<u8>>>>>,
) {
    // Parse and connect to local TCP port
    let local_port = match parse_forward_port(&local_spec) {
        Ok(p) => p,
        Err(e) => {
            warn!("Failed to parse local spec '{local_spec}': {e}");
            return;
        }
    };

    let stream = match tokio::net::TcpStream::connect(format!("127.0.0.1:{local_port}")).await {
        Ok(s) => s,
        Err(e) => {
            warn!("Rport failed to connect to local port {local_port}: {e}");
            // Send ForwardFreeContext to notify daemon
            let free_payload = forward_id.to_be_bytes().to_vec();
            let free_msg = TaskMessage {
                channel_id,
                command: HdcCommand::ForwardFreeContext,
                payload: free_payload,
            };
            let _ = send_to_session(&tcp_map, &usb_map, session_id, &concat_pack(&free_msg)).await;
            return;
        }
    };

    let (conn_tx, mut conn_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
    forward_conns.lock().await.insert(forward_id, conn_tx);

    let (mut local_rd, mut local_wr) = stream.into_split();

    // Step 1: Send ForwardActiveMaster to daemon
    let master_payload = forward_id.to_be_bytes().to_vec();
    let master_msg = TaskMessage {
        channel_id,
        command: HdcCommand::ForwardActiveMaster,
        payload: master_payload,
    };
    if let Err(e) = send_to_session(&tcp_map, &usb_map, session_id, &concat_pack(&master_msg)).await {
        warn!("Failed to send ForwardActiveMaster for rport forward_id={forward_id}: {e}");
        forward_conns.lock().await.remove(&forward_id);
        return;
    }
    info!("ForwardActiveMaster sent for rport forward_id={forward_id}");

    // Step 2: Bidirectional data bridge (same as fport)
    let usb_map_for_send = usb_map.clone();
    let tcp_map_for_send = tcp_map.clone();
    let forward_id_for_send = forward_id;
    let tcp_to_usb = tokio::spawn(async move {
        let mut buf = vec![0u8; 4096];
        loop {
            match local_rd.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    let mut payload = vec![0u8; 4 + n];
                    payload[..4].copy_from_slice(&forward_id_for_send.to_be_bytes());
                    payload[4..].copy_from_slice(&buf[..n]);
                    let msg = TaskMessage {
                        channel_id,
                        command: HdcCommand::ForwardData,
                        payload,
                    };
                    let data = concat_pack(&msg);
                    if send_to_session(&tcp_map_for_send, &usb_map_for_send, session_id, &data).await.is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    let usb_to_tcp = tokio::spawn(async move {
        while let Some(data) = conn_rx.recv().await {
            if local_wr.write_all(&data).await.is_err() {
                break;
            }
        }
    });

    let _ = tokio::join!(tcp_to_usb, usb_to_tcp);
    info!("Rport bridge closed for forward_id={forward_id}");
    forward_conns.lock().await.remove(&forward_id);

    // Notify daemon to free context
    let free_payload = forward_id.to_be_bytes().to_vec();
    let free_msg = TaskMessage {
        channel_id,
        command: HdcCommand::ForwardFreeContext,
        payload: free_payload,
    };
    let data = concat_pack(&free_msg);
    let _ = send_to_session(&tcp_map, &usb_map, session_id, &data).await;
}

// ============================================================================
// USB device monitor
// ============================================================================

use std::collections::HashSet;
use std::time::Duration;

/// Enumerate HarmonyOS USB devices and start sessions for any newly-discovered
/// devices.  Already-managed devices are tracked in `known_devices`.
async fn process_usb_device_changes(
    known_devices: &Arc<tokio::sync::Mutex<HashSet<String>>>,
    connect_map: &ConnectMap,
    tcp_map: &TcpMap,
    usb_map: &UsbMap,
    forward_map: &ForwardMap,
) {
    let devices = crate::usb::enumerate_harmony_devices().await;
    let mut known = known_devices.lock().await;

    for dev in &devices {
        if !known.contains(&dev.serial_number) {
            known.insert(dev.serial_number.clone());
            info!(
                "USB device discovered: serial={}, VID={:04X}, PID={:04X}",
                dev.serial_number, dev.vendor_id, dev.product_id
            );

            // Add to ConnectMap with Ready status initially
            connect_map.put(dev.serial_number.clone(), DaemonInfo {
                session_id: 0,
                conn_type: ConnectType::Usb(format!("{}", dev.device_address)),
                conn_status: ConnStatus::Ready,
                dev_name: String::new(),
                version: String::new(),
            }).await;

            // Start USB session in background
            let cm = connect_map.clone();
            let tm = tcp_map.clone();
            let um = usb_map.clone();
            let fm = forward_map.clone();
            let kd = known_devices.clone();
            let serial = dev.serial_number.clone();
            tokio::spawn(async move {
                start_usb_session(serial.clone(), cm, tm, um, fm).await;
                // Session ended (success or failure) - remove from known so it can be re-discovered
                kd.lock().await.remove(&serial);
                info!("USB session ended for {serial}, allowing re-discovery");
            });
        }
    }
}

async fn usb_device_monitor(connect_map: ConnectMap, tcp_map: TcpMap, usb_map: UsbMap, forward_map: ForwardMap) {
    let known_devices = Arc::new(tokio::sync::Mutex::new(HashSet::new()));

    // Attempt to use libusb hotplug events; fall back to polling if unavailable.
    let mut hotplug_rx = crate::usb::spawn_hotplug_watcher();
    let use_hotplug = hotplug_rx.is_some();

    // On Windows, libusb hotplug is unavailable.  Use a native WM_DEVICECHANGE
    // watcher instead of aggressive 2 s polling.
    #[cfg(target_os = "windows")]
    let (mut windows_rx, use_windows_hotplug) = if use_hotplug {
        (None, false)
    } else {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        if crate::usb_hotplug_windows::spawn_windows_usb_watcher(tx) {
            info!("USB device monitor: using Windows native device-change events with 30 s fallback polling");
            (Some(rx), true)
        } else {
            info!("USB device monitor: Windows native watcher unavailable, using 30 s polling");
            (None, false)
        }
    };
    #[cfg(not(target_os = "windows"))]
    let (mut windows_rx, use_windows_hotplug): (Option<tokio::sync::mpsc::UnboundedReceiver<()>>, bool) = (None, false);

    // Keep fallback poll at 2 s so that device plug/unplug is detected
    // quickly even if the native event listener misses an event.
    let poll_interval = Duration::from_secs(2);
    let mut poll_timer = tokio::time::interval(poll_interval);

    loop {
        process_usb_device_changes(&known_devices, &connect_map, &tcp_map, &usb_map, &forward_map).await;

        if use_hotplug {
            tokio::select! {
                _ = hotplug_rx.as_mut().unwrap().recv() => {
                    info!("USB hotplug event received, re-enumerating devices");
                    // Debounce: a single physical plug/unplug may generate
                    // multiple rapid events.
                    tokio::time::sleep(Duration::from_millis(300)).await;
                    while hotplug_rx.as_mut().unwrap().try_recv().is_ok() {}
                }
                _ = poll_timer.tick() => {
                    trace!("USB fallback poll tick");
                }
            }
        } else if use_windows_hotplug {
            tokio::select! {
                _ = windows_rx.as_mut().unwrap().recv() => {
                    info!("Windows USB device-change event received, re-enumerating devices");
                    // Debounce: a single physical plug/unplug may generate
                    // multiple rapid events.
                    tokio::time::sleep(Duration::from_millis(300)).await;
                    while windows_rx.as_mut().unwrap().try_recv().is_ok() {}
                }
                _ = poll_timer.tick() => {
                    trace!("USB fallback poll tick");
                }
            }
        } else {
            poll_timer.tick().await;
        }
    }
}

/// Start a USB session with a HarmonyOS device.
async fn start_usb_session(
    serial: String,
    connect_map: ConnectMap,
    tcp_map: TcpMap,
    usb_map: UsbMap,
    forward_map: ForwardMap,
) {
    info!("Starting USB session for device {serial}");

    let connection = match crate::usb::connect_usb_device(&serial).await {
        Ok(conn) => conn,
        Err(e) => {
            error!("Failed to connect USB device {serial}: {e}");
            connect_map.update_status(&serial, ConnStatus::Offline).await;
            return;
        }
    };

    let mut session_id = rand::random::<u32>();
    let max_packet_size = connection.max_packet_size;
    let bulk_in = connection.bulk_in;
    let bulk_out = connection.bulk_out;

    // Wrap in Arc so writer and reader can share the connection concurrently.
    let conn = std::sync::Arc::new(connection);

    // Step 1: Send soft-reset to daemon
    info!("Sending USB soft-reset for {serial}");
    if let Err(e) = crate::transfer::usb::send_usb_soft_reset(&*conn, bulk_out, 0).await {
        error!("USB soft-reset send failed for {serial}: {e}");
        connect_map.update_status(&serial, ConnStatus::Offline).await;
        return;
    }

    // Step 2: Clear USB channel - read and discard stale data for a short period
    info!("Clearing USB channel for {serial}");
    let clear_start = std::time::Instant::now();
    let clear_timeout = std::time::Duration::from_millis(1000);
    let mut drop_bytes: usize = 0;
    loop {
        let elapsed = clear_start.elapsed();
        if elapsed >= clear_timeout {
            break;
        }
        let remaining = clear_timeout - elapsed;
        match tokio::time::timeout(remaining, crate::transfer::usb::read_usb_drop(&*conn, bulk_in, 512)).await {
            Ok(Ok(0)) => break,
            Ok(Ok(n)) => {
                drop_bytes += n;
                continue;
            }
            Ok(Err(_)) => break,
            Err(_) => break,
        }
    }
    info!("USB channel cleared for {serial}, dropped {drop_bytes} bytes");

    // Step 3 & 4: Send initial handshake and perform authentication exchange
    let auth_tlv = format!("authtype{:8}1{:15}1", "", "");
    let version_with_hash = format!("{}{}", get_version(), "47d583e40754ffe6");
    let mut handshake = SessionHandShake {
        banner: HANDSHAKE_MESSAGE.to_string(),
        auth_type: AuthType::None as u8,
        session_id,
        connect_key: serial.clone(),
        buf: auth_tlv,
        version: version_with_hash,
    };

    let msg = TaskMessage {
        channel_id: 0,
        command: HdcCommand::KernelHandshake,
        payload: handshake.serialize(),
    };
    if let Err(e) = crate::transfer::usb::send_usb_message(&*conn, bulk_out, session_id, &msg, max_packet_size).await {
        error!("USB handshake send failed for {serial}: {e}");
        connect_map.update_status(&serial, ConnStatus::Offline).await;
        return;
    }
    info!("USB initial handshake sent for {serial}, waiting for daemon response...");

    // Authentication exchange loop
    let mut auth_attempts = 0u32;
    let mut last_daemon_buf = String::new();
    const MAX_AUTH_ATTEMPTS: u32 = 10;
    let auth_ok = loop {
        auth_attempts += 1;
        if auth_attempts > MAX_AUTH_ATTEMPTS {
            error!("USB authentication exceeded max attempts for {serial}");
            break false;
        }

        // After sending public key (attempt 2), device may show a UI confirmation dialog.
        // Give the user 60 seconds to confirm on the device.
        let recv_timeout = if auth_attempts == 2 {
            std::time::Duration::from_secs(60)
        } else {
            std::time::Duration::from_secs(10)
        };

        let (resp_session_id, daemon_resp) = match tokio::time::timeout(
            recv_timeout,
            crate::transfer::usb::recv_usb_message(&*conn, bulk_in)
        ).await {
            Ok(Ok(r)) => r,
            Ok(Err(e)) => {
                error!("USB auth recv failed for {serial}: {e}");
                break false;
            }
            Err(_) => {
                if auth_attempts == 2 {
                    error!("USB auth timeout for {serial} after 60s. Please check if the device shows a USB debugging authorization dialog and confirm it on the device.");
                } else {
                    error!("USB auth timeout for {serial}");
                }
                break false;
            }
        };

        if daemon_resp.command != HdcCommand::KernelHandshake {
            warn!("Unexpected command during auth for {serial}: {:?}", daemon_resp.command);
            continue;
        }

        let daemon_hs = match SessionHandShake::deserialize(&daemon_resp.payload) {
            Ok(hs) => hs,
            Err(e) => {
                error!("Failed to deserialize daemon handshake for {serial}: {e}");
                break false;
            }
        };
        last_daemon_buf = daemon_hs.buf.clone();

        // Update session_id from daemon response (daemon may assign a new session_id)
        if resp_session_id != 0 && resp_session_id != session_id {
            info!("Updating session_id for {serial}: {} -> {resp_session_id}", session_id);
            session_id = resp_session_id;
            handshake.session_id = session_id;
        }

        info!("Daemon auth response for {serial}: auth_type={}, buf_len={}", daemon_hs.auth_type, daemon_hs.buf.len());

        match daemon_hs.auth_type {
            x if x == AuthType::Ok as u8 => {
                info!("USB authentication successful for {serial}");
                break true;
            }
            x if x == AuthType::Fail as u8 => {
                error!("USB authentication rejected by daemon for {serial}");
                break false;
            }
            x if x == AuthType::Publickey as u8 => {
                info!("Daemon requests public key for {serial}");
                let pubkey_info = match crate::auth::get_public_key_info() {
                    Ok(info) => info,
                    Err(e) => {
                        error!("Failed to get public key info for {serial}: {e}");
                        break false;
                    }
                };
                handshake.auth_type = AuthType::Publickey as u8;
                handshake.buf = pubkey_info;

                let msg = TaskMessage {
                    channel_id: 0,
                    command: HdcCommand::KernelHandshake,
                    payload: handshake.serialize(),
                };
                if let Err(e) = crate::transfer::usb::send_usb_message(&*conn, bulk_out, session_id, &msg, max_packet_size).await {
                    error!("Failed to send public key for {serial}: {e}");
                    break false;
                }
                info!("Public key sent to daemon for {serial}. If this is the first connection, please confirm USB debugging authorization on the device.");
            }
            x if x == AuthType::Signature as u8 => {
                info!("Daemon sends signature challenge for {serial}");
                let challenge = daemon_hs.buf;
                let signature = match crate::auth::rsa_sign_challenge(&challenge) {
                    Ok(sig) => sig,
                    Err(e) => {
                        error!("Failed to sign challenge for {serial}: {e}");
                        break false;
                    }
                };
                handshake.auth_type = AuthType::Signature as u8;
                handshake.buf = signature;

                let msg = TaskMessage {
                    channel_id: 0,
                    command: HdcCommand::KernelHandshake,
                    payload: handshake.serialize(),
                };
                if let Err(e) = crate::transfer::usb::send_usb_message(&*conn, bulk_out, session_id, &msg, max_packet_size).await {
                    error!("Failed to send signature for {serial}: {e}");
                    break false;
                }
                info!("Signature sent to daemon for {serial}");
            }
            x if x == AuthType::Token as u8 => {
                warn!("Daemon requested token auth for {serial}, not supported");
                break false;
            }
            other => {
                warn!("Unknown auth type from daemon for {serial}: {other}");
                break false;
            }
        }
    };

    if !auth_ok {
        connect_map.update_status(&serial, ConnStatus::Offline).await;
        return;
    }

    // Update ConnectMap to Connected
    let dev_name = {
        let tlv_map = parse_tlv(&last_daemon_buf);
        tlv_map.get("devname").cloned().unwrap_or_default()
    };
    connect_map.put(serial.clone(), DaemonInfo {
        session_id,
        conn_type: ConnectType::Usb(serial.clone()),
        conn_status: ConnStatus::Connected,
        dev_name,
        version: String::new(),
    }).await;

    // Create channel for sending data to USB
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
    usb_map.start_session(session_id, tx).await;

    // Spawn writer task
    let serial_for_writer = serial.clone();
    let usb_map_for_cleanup = usb_map.clone();
    let writer_conn = conn.clone();
    let writer_task = tokio::spawn(async move {
        while let Some(payload) = rx.recv().await {
            if let Err(e) = crate::transfer::usb::send_usb_raw(&*writer_conn, bulk_out, session_id, &payload, max_packet_size).await {
                warn!("USB write error for {serial_for_writer}: {e}");
                break;
            }
        }
        let _ = usb_map_for_cleanup.end_session(session_id).await;
    });

    // Read loop: forward daemon responses to client channels
    let serial_for_reader = serial.clone();
    let reader_conn = conn.clone();
    loop {
        match crate::transfer::usb::recv_usb_message(&*reader_conn, bulk_in).await {
            Ok((_resp_session_id, task)) => {
                let payload_preview = String::from_utf8_lossy(&task.payload[..task.payload.len().min(100)]);
                info!("USB recv for {serial_for_reader}: cmd={:?}, channel_id={}, payload_len={}, payload_preview='{}'",
                    task.command, task.channel_id, task.payload.len(), payload_preview.trim_end());
                if task.command == HdcCommand::KernelHandshake {
                    // Daemon may send additional handshake messages after auth OK (e.g., new signature challenge)
                    if let Ok(daemon_hs) = SessionHandShake::deserialize(&task.payload) {
                        match daemon_hs.auth_type {
                            x if x == AuthType::Signature as u8 => {
                                info!("Daemon sends post-auth signature challenge for {serial_for_reader}");
                                if let Ok(signature) = crate::auth::rsa_sign_challenge(&daemon_hs.buf) {
                                    let mut reply_hs = SessionHandShake {
                                        banner: HANDSHAKE_MESSAGE.to_string(),
                                        auth_type: AuthType::Signature as u8,
                                        session_id,
                                        connect_key: serial_for_reader.clone(),
                                        buf: signature,
                                        version: format!("{}{}", get_version(), "47d583e40754ffe6"),
                                    };
                                    let reply_msg = TaskMessage {
                                        channel_id: 0,
                                        command: HdcCommand::KernelHandshake,
                                        payload: reply_hs.serialize(),
                                    };
                                    let reply_data = concat_pack(&reply_msg);
                                    if let Err(e) = usb_map.send_to_session(session_id, &reply_data).await {
                                        warn!("Failed to send post-auth signature reply for {serial_for_reader}: {e}");
                                    } else {
                                        info!("Post-auth signature reply sent for {serial_for_reader}");
                                    }
                                }
                            }
                            x if x == AuthType::Ok as u8 => {
                                info!("Daemon sends post-auth OK for {serial_for_reader}");
                            }
                            other => {
                                warn!("Unexpected post-auth auth type from daemon for {serial_for_reader}: {other}");
                            }
                        }
                    }
                } else if usb_map.route_response(session_id, task.channel_id, task.clone()).await {
                    // Response was routed to a registered handler (file transfer, app install, shell, forward)
                    // Do not forward to TCP client
                } else if task.command == HdcCommand::KernelEcho {
                    // KernelEcho payload format: [level_byte, message_bytes]. The leading
                    // level byte is intended for CLI log filtering and must not be sent to
                    // IDE clients (e.g. DevEco Studio), which parse the raw daemon message.
                    let payload = if task.payload.is_empty() {
                        &task.payload[..]
                    } else {
                        &task.payload[1..]
                    };
                    let _ = tcp_map.send_channel_message(task.channel_id, payload).await;
                } else if task.command == HdcCommand::KernelEchoRaw {
                    let _ = tcp_map.send_channel_message(task.channel_id, &task.payload).await;
                } else if task.command == HdcCommand::KernelChannelClose {
                    // Official server sends KernelChannelClose as HDC protocol message which
                    // the client ignores. Since send_channel_message sends length-prefixed
                    // raw data, forwarding the payload would corrupt client output.
                    let _ = tcp_map.end_channel(task.channel_id).await;
                } else if matches!(
                    task.command,
                    HdcCommand::FileInit | HdcCommand::FileCheck | HdcCommand::UnityBugreportInit
                ) {
                    // Official 3.2.0f CheckHostCommandPermission: daemon-initiated file or
                    // bugreport writes to the host are only valid while a matching client
                    // request is active (routed above). Anything else is unauthorized.
                    warn!(
                        "Drop unauthorized {:?} from daemon sid={} cid={}",
                        task.command, session_id, task.channel_id
                    );
                } else {
                    let _ = tcp_map.send_channel_message(task.channel_id, &task.payload).await;
                }
            }
            Err(e) => {
                // Ignore nop/reset packets during normal operation
                if e.kind() == ErrorKind::InvalidData && e.to_string().contains("nop/reset") {
                    continue;
                }
                warn!("USB read error for {serial_for_reader}: {e}");
                break;
            }
        }
    }

    // Cleanup
    connect_map.remove(&serial).await;
    // Drop session sender AND all response channels so that bridge tasks
    // (shell, file transfer, forward) waiting on rx.recv() are unblocked.
    usb_map.end_session_with_cleanup(session_id).await;
    let _ = writer_task.await;
    // Close all TCP client channels still associated with this session so
    // single-command clients (e.g. hdc shell pwd) don't hang forever.
    tcp_map.close_session_channels(session_id).await;
    // Clean up any port forwarding entries for this device so listeners
    // do not keep accepting connections after disconnect.
    let _ = remove_forward_entry(&tcp_map, &usb_map, &forward_map, &serial, 0, "").await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::write::SimpleFileOptions;

    #[test]
    fn extract_haps_from_app_finds_hap_files() {
        let temp_dir = std::env::temp_dir().join(format!("hdc_app_test_{}", rand::random::<u32>()));
        std::fs::create_dir_all(&temp_dir).unwrap();
        let app_path = temp_dir.join("test.app");
        let out_dir = temp_dir.join("extracted");
        std::fs::create_dir_all(&out_dir).unwrap();

        {
            let file = std::fs::File::create(&app_path).unwrap();
            let mut zip = zip::ZipWriter::new(file);
            let options = SimpleFileOptions::default();
            zip.start_file("entry-default-signed.hap", options).unwrap();
            zip.write_all(b"fake hap 1").unwrap();
            zip.start_file("feature/Feature.hap", options).unwrap();
            zip.write_all(b"fake hap 2").unwrap();
            zip.start_file("readme.txt", options).unwrap();
            zip.write_all(b"not hap").unwrap();
            zip.finish().unwrap();
        }

        let haps = extract_haps_from_app(app_path.to_str().unwrap(), &out_dir).unwrap();
        assert_eq!(haps.len(), 2);
        let names: Vec<_> = haps.iter()
            .map(|p| p.file_name().unwrap().to_str().unwrap().to_string())
            .collect();
        assert!(names.contains(&"entry-default-signed.hap".to_string()));
        assert!(names.contains(&"Feature.hap".to_string()));

        let _ = std::fs::remove_dir_all(&temp_dir);
    }
}
