//! AMCL完整HDC嵌入层。固定上游保留认证、客户端、服务器、USB、网络发现和传输模块。
//! 仅运行手机本机TCP通道；内部客户端增加私有接入，不修改HOME或全局stdout/stderr。
#[path="upstream/auth.rs"] mod auth;
#[path="upstream/client.rs"] mod client;
#[path="upstream/server.rs"] mod server;
#[path="../../../../../../../prebuilt/hdc/muka-rust-hdc/hdc/src/net_discover.rs"] mod net_discover;
#[path="../../../../../../../prebuilt/hdc/muka-rust-hdc/hdc/src/parser.rs"] mod parser;
#[path="../../../../../../../prebuilt/hdc/muka-rust-hdc/hdc/src/transfer/mod.rs"] mod transfer;
#[path="../../../../../../../prebuilt/hdc/muka-rust-hdc/hdc/src/usb.rs"] mod usb;
mod admission;
mod output;
mod send_completion;
mod local_probe;

use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU16, Ordering};
use std::time::Duration;
use std::sync::OnceLock;
static STARTED: AtomicBool = AtomicBool::new(false);
static PORT: AtomicU16 = AtomicU16::new(0);
static START_ERROR: AtomicI32 = AtomicI32::new(0);
static STOP: OnceLock<tokio::sync::Notify> = OnceLock::new();
static POW_GENERATION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// 新挑战及取消都切换代次；在入队时取得代次，防止取消后才启动的旧 worker 继续耗 CPU。
#[no_mangle]
pub extern "C" fn amcl_hdc_core_next_pow() -> u64 { POW_GENERATION.fetch_add(1, Ordering::AcqRel) + 1 }

/// 服务器成功bind/listen后发布实际端口；调用方不能把“线程已创建”当作服务就绪。
pub(crate) fn report_listening(port: u16) { PORT.store(port, Ordering::Release); }

/// C ABI只复制本次调用期间有效的UTF-8，不保存调用方指针。
unsafe fn text(pointer: *const c_char) -> Result<String, ()> {
    if pointer.is_null() { return Err(()); }
    CStr::from_ptr(pointer).to_str().map(str::to_owned).map_err(|_| ())
}

/// 从NAPI异步worker调用；返回正数实际端口，负数为初始化错误。身份目录必须由受控上层提供。
#[no_mangle]
pub unsafe extern "C" fn amcl_hdc_core_start(root: *const c_char) -> i32 {
    let root = match text(root) { Ok(root) => root, Err(_) => return -1 };
    if STARTED.load(Ordering::Acquire) {
        let port = PORT.load(Ordering::Acquire);
        return if port == 0 { -2 } else { i32::from(port) };
    }
    if STARTED.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_err() { return -2; }
    if auth::set_identity_root(root).is_err() { STARTED.store(false, Ordering::Release); return -3; }
    admission::initialize();
    server::set_usb_discovery_enabled(false);
    server::set_forward_listen_ip("127.0.0.1".to_owned());
    START_ERROR.store(0, Ordering::Release);
    std::thread::spawn(|| {
        let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build();
        let result = match runtime {
            Ok(runtime) => runtime.block_on(async {
                // Runtime退出会取消其全部连接任务；服务闲置或更新失败后不长期保持调试host。
                tokio::select! {
                    result = server::run_server_mode("127.0.0.1:0", server::ConnectMap::new(), server::TcpMap::new(), server::UsbMap::new()) => result,
                    _ = STOP.get_or_init(tokio::sync::Notify::new).notified() => Ok(())
                }
            }),
            Err(error) => Err(std::io::Error::new(std::io::ErrorKind::Other, error.to_string())),
        };
        PORT.store(0, Ordering::Release);
        if result.is_err() {
            START_ERROR.store(-4, Ordering::Release);
        }
        STARTED.store(false, Ordering::Release);
    });
    // 只在异步worker等待短窗口，不阻塞ArkUI线程；bind失败不会把旧/冒名端口当作成功。
    for _ in 0..150 {
        let port = PORT.load(Ordering::Acquire);
        if port != 0 { return i32::from(port); }
        let error = START_ERROR.load(Ordering::Acquire);
        if error != 0 { return error; }
        std::thread::sleep(Duration::from_millis(20));
    }
    -5
}

/// 停止仅属于AMCL的运行时，不关闭系统daemon或其他调试会话。调用方必须等在途命令完成。
#[no_mangle]
pub extern "C" fn amcl_hdc_core_stop() -> i32 {
    if !STARTED.load(Ordering::Acquire) { return 0; }
    STOP.get_or_init(tokio::sync::Notify::new).notify_one();
    for _ in 0..150 {
        if !STARTED.load(Ordering::Acquire) { return 0; }
        std::thread::sleep(Duration::from_millis(20));
    }
    -8
}

/// 枫源 V2 顺序模平方，在 NAPI 后台 worker 中执行。固定 384 字节输入输出，次数与时间有界。
/// 不涉及 RSA 私钥或签名；输入为公开工作量挑战，绝不使用陷门跳过要求的顺序计算。
#[no_mangle]
pub unsafe extern "C" fn amcl_hdc_core_pow(modulus: *const c_char, base: *const c_char, iterations: i32,
                                         output: *mut c_char, capacity: usize, generation: u64) -> i32 {
    if output.is_null() || capacity < 769 || !(1..=1_000_000).contains(&iterations) { return -1; }
    let n_text = match text(modulus) { Ok(s) if s.len() == 768 && s.bytes().all(|c| c.is_ascii_hexdigit()) => s, _ => return -2 };
    let y_text = match text(base) { Ok(s) if s.len() == 768 && s.bytes().all(|c| c.is_ascii_hexdigit()) => s, _ => return -2 };
    let n = match rsa::BigUint::parse_bytes(n_text.as_bytes(), 16) { Some(n) if n.bits() > 1 => n, _ => return -3 };
    let mut y = match rsa::BigUint::parse_bytes(y_text.as_bytes(), 16) { Some(y) if y.bits() > 0 && y < n => y, _ => return -3 };
    let started = std::time::Instant::now();
    for count in 0..iterations {
        if count % 64 == 0 && POW_GENERATION.load(Ordering::Acquire) != generation { return -5; }
        y = (&y * &y) % &n;
        if count % 1024 == 0 && started.elapsed() > Duration::from_secs(90) { return -4; }
    }
    let encoded = format!("{:0>768}", y.to_str_radix(16));
    std::ptr::copy_nonoverlapping(encoded.as_ptr(), output.cast::<u8>(), 768);
    *output.add(768) = 0;
    0
}

#[cfg(test)]
mod pow_tests {
    use super::*;
    use std::ffi::CString;

    /// 独立已知向量：3^(2^3) mod 17 = 16，结果必须仍为 384 字节而不是单字节。
    #[test]
    fn fixed_width_solution_and_cancellation() {
        let modulus = CString::new(format!("{:0>768}", "11")).unwrap();
        let base = CString::new(format!("{:0>768}", "3")).unwrap();
        let generation = amcl_hdc_core_next_pow();
        let mut output = [0i8; 769];
        assert_eq!(unsafe { amcl_hdc_core_pow(modulus.as_ptr(), base.as_ptr(), 3, output.as_mut_ptr(), output.len(), generation) }, 0);
        let value = unsafe { CStr::from_ptr(output.as_ptr()) }.to_str().unwrap();
        assert_eq!(value, format!("{:0>768}", "10"));
        amcl_hdc_core_next_pow();
        assert_eq!(unsafe { amcl_hdc_core_pow(modulus.as_ptr(), base.as_ptr(), 3, output.as_mut_ptr(), output.len(), generation) }, -5);
        assert_eq!(unsafe { amcl_hdc_core_pow(modulus.as_ptr(), base.as_ptr(), 0, output.as_mut_ptr(), output.len(), generation) }, -1);
    }
}

/// 完整客户端执行。上层只构造固定更新操作；参数用制表符分隔，拒绝开启另一个host。
#[no_mangle]
pub unsafe extern "C" fn amcl_hdc_core_command(arguments: *const c_char) -> i32 {
    execute_command(arguments, None)
}

/// 查询结果只写到调用方给出的应用私有文件，不把UDID等内容输出到日志或JS结果。
#[no_mangle]
pub unsafe extern "C" fn amcl_hdc_core_command_to_file(arguments: *const c_char, output_path: *const c_char) -> i32 {
    let path = match text(output_path) { Ok(path) if !path.is_empty() => path, _ => return -9 };
    execute_command(arguments, Some(path))
}

/// 两种结果模式共用同一服务器约束、解析器与有界生命周期。
unsafe fn execute_command(arguments: *const c_char, output_path: Option<String>) -> i32 {
    let port = PORT.load(Ordering::Acquire);
    if !STARTED.load(Ordering::Acquire) || port == 0 { return -1; }
    let arguments = match text(arguments) { Ok(arguments) => arguments, Err(_) => return -2 };
    let parsed = match parser::parse_command(arguments.split('\t').map(str::to_owned)) {
        Ok(parsed) => parsed, Err(_) => return -3,
    };
    if parsed.run_in_server || parsed.server_addr != format!("127.0.0.1:{port}") { return -4; }
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime, Err(_) => return -5,
    };
    // 连接与短shell检查应及时返回，让用户补授权后重试；大HAP传输保留原有三分钟窗口。
    let timeout = if parsed.parameters.first().map(|s| s.as_str()) == Some("file") { 180 } else { 20 };
    runtime.block_on(async {
        if let Some(path) = output_path {
            return match tokio::time::timeout(Duration::from_secs(timeout), client::run_client_mode_capture(parsed)).await {
                Ok(Ok(bytes)) => {
                    use std::io::Write;
                    let mut options = std::fs::OpenOptions::new();
                    options.write(true).create(true).truncate(true);
                    #[cfg(unix)] {
                        use std::os::unix::fs::OpenOptionsExt;
                        options.mode(0o600);
                    }
                    match options.open(path).and_then(|mut file| { file.write_all(&bytes)?; file.sync_all() }) { Ok(()) => 0, Err(_) => -9 }
                },
                Ok(Err(_)) => -6, Err(_) => -7,
            };
        }
        match tokio::time::timeout(Duration::from_secs(timeout), client::run_client_mode(parsed)).await {
            Ok(Ok(())) => 0, Ok(Err(_)) => -6, Err(_) => -7,
        }
    })
}
