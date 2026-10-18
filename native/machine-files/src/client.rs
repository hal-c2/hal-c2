//! A 9P client whose calls may run at once from many threads: each waits on its own
//! tag while one reader hands the replies out. When the input ends every call still
//! waiting, and every later one, fails with EIO.

use crate::p9::{self, NOTAG, R, T};
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::sync::Mutex;
use std::sync::mpsc::{Sender, channel};

pub const EIO: i32 = 5;
/// Nothing the MC sends is bigger: its msize is a megabyte and a bit.
const MAX_MESSAGE: u32 = 2 * 1024 * 1024;

pub struct Client {
    out: Mutex<Box<dyn Write + Send>>,
    state: Mutex<State>,
}

struct State {
    next: u16,
    waiting: HashMap<u16, Sender<R>>,
    closed: bool,
}

impl Client {
    pub fn new(out: Box<dyn Write + Send>) -> Client {
        let state = State {
            next: 0,
            waiting: HashMap::new(),
            closed: false,
        };
        Client {
            out: Mutex::new(out),
            state: Mutex::new(state),
        }
    }

    /// Sends `t` and waits for its reply; an Rlerror is its errno.
    pub fn call(&self, t: &T) -> Result<R, i32> {
        self.send(t, None)
    }

    /// Agrees on 9P2000.L and `msize`, before any other call.
    pub fn version(&self, msize: u32) -> Result<u32, i32> {
        match self.send(&T::Version { msize }, Some(NOTAG))? {
            R::Version { msize, version } if version == p9::VERSION => Ok(msize),
            _ => Err(EIO),
        }
    }

    fn send(&self, t: &T, tag: Option<u16>) -> Result<R, i32> {
        let (tx, rx) = channel();
        let tag = {
            let mut state = self.state.lock().unwrap();
            if state.closed {
                return Err(EIO);
            }
            let tag = tag.unwrap_or_else(|| state.free_tag());
            state.waiting.insert(tag, tx);
            tag
        };
        let sent = {
            let mut out = self.out.lock().unwrap();
            out.write_all(&t.encode(tag)).and_then(|()| out.flush())
        };
        if sent.is_err() {
            self.state.lock().unwrap().waiting.remove(&tag);
            return Err(EIO);
        }
        match rx.recv() {
            Ok(R::Lerror(errno)) => Err(errno as i32),
            Ok(r) => Ok(r),
            Err(_closed) => Err(EIO),
        }
    }

    /// Hands out the replies read from `input` until it ends, then fails what waits.
    pub fn read_replies(&self, mut input: impl Read) -> io::Result<()> {
        let result = (|| loop {
            let mut head = [0u8; 7];
            input.read_exact(&mut head)?;
            let (size, kind, tag) = p9::header(head);
            if !(7..=MAX_MESSAGE).contains(&size) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "bad 9P message size",
                ));
            }
            let mut body = vec![0u8; size as usize - 7];
            input.read_exact(&mut body)?;
            let reply = p9::decode(kind, &body).unwrap_or_else(|bad| {
                eprintln!("machine-files: {bad}");
                R::Lerror(EIO as u32)
            });
            if let Some(waiting) = self.state.lock().unwrap().waiting.remove(&tag) {
                let _ = waiting.send(reply);
            }
        })();
        self.close();
        match result {
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => Ok(()),
            other => other,
        }
    }

    fn close(&self) {
        let mut state = self.state.lock().unwrap();
        state.closed = true;
        state.waiting.clear();
    }
}

impl State {
    fn free_tag(&mut self) -> u16 {
        loop {
            let tag = self.next;
            self.next = self.next.wrapping_add(1);
            if tag != NOTAG && !self.waiting.contains_key(&tag) {
                return tag;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::mpsc::Receiver;
    use std::thread;

    /// What the client writes, frame by frame.
    struct Wire(Sender<Vec<u8>>);
    impl Write for Wire {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.0.send(buf.to_vec()).unwrap();
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    /// What the client reads: the frames sent into it, then its end.
    struct Feed(Receiver<Vec<u8>>, Vec<u8>);
    impl Read for Feed {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            if self.1.is_empty() {
                match self.0.recv() {
                    Ok(next) => self.1 = next,
                    Err(_) => return Ok(0),
                }
            }
            let n = buf.len().min(self.1.len());
            buf[..n].copy_from_slice(&self.1[..n]);
            self.1.drain(..n);
            Ok(n)
        }
    }

    fn reply(kind: u8, tag: u16, body: &[u8]) -> Vec<u8> {
        let mut out = ((body.len() + 7) as u32).to_le_bytes().to_vec();
        out.push(kind);
        out.extend_from_slice(&tag.to_le_bytes());
        out.extend_from_slice(body);
        out
    }

    fn tag_of(frame: &[u8]) -> u16 {
        u16::from_le_bytes([frame[5], frame[6]])
    }

    /// The client, what it sends, where its replies go in, and its reader.
    type Harness = (
        Arc<Client>,
        Receiver<Vec<u8>>,
        Sender<Vec<u8>>,
        thread::JoinHandle<io::Result<()>>,
    );

    fn setup() -> Harness {
        let (out_tx, out_rx) = channel();
        let (in_tx, in_rx) = channel();
        let client = Arc::new(Client::new(Box::new(Wire(out_tx))));
        let reader = {
            let client = client.clone();
            thread::spawn(move || client.read_replies(Feed(in_rx, Vec::new())))
        };
        (client, out_rx, in_tx, reader)
    }

    #[test]
    fn replies_reach_their_callers_in_any_order() {
        let (client, sent, replies, _reader) = setup();
        let calls: Vec<_> = (0..2)
            .map(|fid| {
                let client = client.clone();
                thread::spawn(move || client.call(&T::Clunk { fid }))
            })
            .collect();
        let first = tag_of(&sent.recv().unwrap());
        let second = tag_of(&sent.recv().unwrap());
        assert_ne!(first, second);
        replies.send(reply(7, second, &2u32.to_le_bytes())).unwrap();
        replies.send(reply(121, first, &[])).unwrap();
        let mut results: Vec<_> = calls.into_iter().map(|c| c.join().unwrap()).collect();
        results.sort_by_key(|r| r.is_err());
        assert_eq!(results, vec![Ok(R::Clunk), Err(2)]);
    }

    #[test]
    fn version_agrees_on_the_size() {
        let (client, sent, replies, _reader) = setup();
        let call = {
            let client = client.clone();
            thread::spawn(move || client.version(1 << 20))
        };
        assert_eq!(tag_of(&sent.recv().unwrap()), NOTAG);
        let mut body = 8192u32.to_le_bytes().to_vec();
        body.extend(8u16.to_le_bytes());
        body.extend(b"9P2000.L");
        replies.send(reply(101, NOTAG, &body)).unwrap();
        assert_eq!(call.join().unwrap(), Ok(8192));
    }

    #[test]
    fn the_end_of_the_input_fails_what_waits_and_what_comes_after() {
        let (client, sent, replies, reader) = setup();
        let call = {
            let client = client.clone();
            thread::spawn(move || client.call(&T::Clunk { fid: 1 }))
        };
        sent.recv().unwrap();
        drop(replies);
        assert_eq!(call.join().unwrap(), Err(EIO));
        assert!(reader.join().unwrap().is_ok());
        assert_eq!(client.call(&T::Clunk { fid: 2 }), Err(EIO));
    }

    #[test]
    fn a_reply_that_does_not_parse_fails_its_call() {
        let (client, sent, replies, _reader) = setup();
        let call = {
            let client = client.clone();
            thread::spawn(move || client.call(&T::Clunk { fid: 1 }))
        };
        let tag = tag_of(&sent.recv().unwrap());
        replies.send(reply(121, tag, &[1, 2])).unwrap();
        assert_eq!(call.join().unwrap(), Err(EIO));
    }
}
