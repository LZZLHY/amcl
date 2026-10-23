//! 每个HDC客户端独占的有界返回缓冲。只收集命令返回帧，不重定向进程stdout。
use std::io::{Error, ErrorKind, Result};

pub(crate) struct CapturedOutput { bytes: Vec<u8> }
impl CapturedOutput {
    pub(crate) fn new() -> Self { Self { bytes: Vec::new() } }
    /// 先检查总量再追加，超限不保留半帧；64KiB足够设备标识等固定短查询。
    pub(crate) fn append(&mut self, packet: &[u8]) -> Result<()> {
        if packet.len() > 65536 - self.bytes.len() {
            return Err(Error::new(ErrorKind::InvalidData, "HDC response exceeds limit"));
        }
        self.bytes.extend_from_slice(packet); Ok(())
    }
    pub(crate) fn into_bytes(self) -> Vec<u8> { self.bytes }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fragmented_and_independent_responses() {
        let mut first = CapturedOutput::new(); let mut second = CapturedOutput::new();
        first.append(b"udid\r").unwrap(); second.append(b"unrelated").unwrap();
        first.append(b"\nvalue\n").unwrap();
        assert_eq!(first.into_bytes(), b"udid\r\nvalue\n");
        assert_eq!(second.into_bytes(), b"unrelated");
    }
    #[test]
    fn overflow_does_not_append_partial_frame() {
        let mut output = CapturedOutput::new(); output.append(&vec![7; 65535]).unwrap();
        assert!(output.append(&[8, 9]).is_err()); output.append(&[10]).unwrap();
        let bytes = output.into_bytes(); assert_eq!(bytes.len(), 65536); assert_eq!(bytes[65535], 10);
    }
}
