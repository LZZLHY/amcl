//! HDC发送方的文件完成握手。数据已发出不等于接收端已经写完；必须先收到接收端的1，
//! 再发送0确认，最后等待通道关闭。错误/提前关闭均不得把残缺文件报告为成功。
use std::io::{Error, ErrorKind, Result};

#[derive(Default)]
pub(crate) struct SendCompletion { receiver_complete: bool, acknowledged: bool }
impl SendCompletion {
    /// 只接受单字节协议标志。首次接收端完成通知要求调用方发送0；重复通知不重复派发。
    pub(crate) fn receiver_finish(&mut self, payload: &[u8]) -> Result<Option<u8>> {
        match payload {
            [1] if !self.receiver_complete => { self.receiver_complete = true; Ok(Some(0)) }
            [1] => Ok(None),
            [0] if self.acknowledged => Ok(None),
            _ => Err(Error::new(ErrorKind::InvalidData, "file ended before receiver write completion")),
        }
    }
    /// 仅在实际发送确认成功后推进状态，发送错误不能借接收端通知变成成功。
    pub(crate) fn acknowledged(&mut self) -> Result<()> {
        if !self.receiver_complete { return Err(Error::new(ErrorKind::InvalidData, "premature file acknowledgement")); }
        self.acknowledged = true; Ok(())
    }
    pub(crate) fn channel_closed(&self) -> Result<()> {
        if self.receiver_complete && self.acknowledged { Ok(()) }
        else { Err(Error::new(ErrorKind::UnexpectedEof, "file channel closed before write completion")) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn writer_must_finish_before_sender_acknowledges_and_closes() {
        let mut completion = SendCompletion::default();
        assert!(completion.channel_closed().is_err());
        assert!(completion.acknowledged().is_err());
        assert_eq!(completion.receiver_finish(&[1]).unwrap(), Some(0));
        assert!(completion.channel_closed().is_err());
        completion.acknowledged().unwrap();
        assert!(completion.channel_closed().is_ok());
    }
    #[test]
    fn reject_early_zero_empty_and_malformed_finish() {
        for payload in [&[][..], &[0][..], &[2][..], &[1, 0][..]] {
            let mut completion = SendCompletion::default();
            assert!(completion.receiver_finish(payload).is_err());
            assert!(completion.channel_closed().is_err());
        }
    }
    #[test]
    fn duplicate_receiver_notification_does_not_duplicate_ack() {
        let mut completion = SendCompletion::default();
        assert_eq!(completion.receiver_finish(&[1]).unwrap(), Some(0));
        completion.acknowledged().unwrap();
        assert_eq!(completion.receiver_finish(&[1]).unwrap(), None);
        assert_eq!(completion.receiver_finish(&[0]).unwrap(), None);
        assert!(completion.channel_closed().is_ok());
    }
}
