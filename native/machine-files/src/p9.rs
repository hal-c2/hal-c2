//! The 9P2000.L the helper speaks to its MC: T-messages encoded, R-messages decoded.
//! A message is `size[4] type[1] tag[2] body`, little-endian, `size` counting itself.
//! The MC's side is `HalC2.MachineFiles.NineP`.

use std::fmt;

pub const VERSION: &str = "9P2000.L";
pub const NOTAG: u16 = 0xFFFF;
pub const NOFID: u32 = 0xFFFF_FFFF;
/// Rgetattr's basic fields (P9_GETATTR_BASIC).
pub const GETATTR_BASIC: u64 = 0x7FF;
pub const AT_REMOVEDIR: u32 = 0x200;

pub mod setattr {
    pub const MODE: u32 = 0x1;
    pub const UID: u32 = 0x2;
    pub const GID: u32 = 0x4;
    pub const SIZE: u32 = 0x8;
    pub const ATIME: u32 = 0x10;
    pub const MTIME: u32 = 0x20;
    pub const ATIME_SET: u32 = 0x80;
    pub const MTIME_SET: u32 = 0x100;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Qid {
    pub kind: u8,
    pub version: u32,
    pub path: u64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Time {
    pub sec: u64,
    pub nsec: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Attr {
    pub qid: Qid,
    pub mode: u32,
    pub nlink: u64,
    pub size: u64,
    pub blksize: u64,
    pub blocks: u64,
    pub atime: Time,
    pub mtime: Time,
    pub ctime: Time,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Dirent {
    pub qid: Qid,
    pub offset: u64,
    pub kind: u8,
    pub name: Vec<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Statfs {
    pub kind: u32,
    pub bsize: u32,
    pub blocks: u64,
    pub bfree: u64,
    pub bavail: u64,
    pub files: u64,
    pub ffree: u64,
    pub fsid: u64,
    pub namelen: u32,
}

/// What `setattr` changes: each `Some` sets its bit in `valid`.
#[derive(Clone, Copy, Debug, Default)]
pub struct SetAttr {
    pub mode: Option<u32>,
    pub uid: Option<u32>,
    pub gid: Option<u32>,
    pub size: Option<u64>,
    /// `Some(None)` is "now" on the machine that has the file.
    pub atime: Option<Option<Time>>,
    pub mtime: Option<Option<Time>>,
}

pub enum T<'a> {
    Version {
        msize: u32,
    },
    Attach {
        fid: u32,
        n_uname: u32,
    },
    Walk {
        fid: u32,
        newfid: u32,
        names: &'a [&'a [u8]],
    },
    Getattr {
        fid: u32,
    },
    Setattr {
        fid: u32,
        set: SetAttr,
    },
    Lopen {
        fid: u32,
        flags: u32,
    },
    Lcreate {
        fid: u32,
        name: &'a [u8],
        flags: u32,
        mode: u32,
        gid: u32,
    },
    Read {
        fid: u32,
        offset: u64,
        count: u32,
    },
    Write {
        fid: u32,
        offset: u64,
        data: &'a [u8],
    },
    Clunk {
        fid: u32,
    },
    Readdir {
        fid: u32,
        offset: u64,
        count: u32,
    },
    Mkdir {
        fid: u32,
        name: &'a [u8],
        mode: u32,
        gid: u32,
    },
    Renameat {
        old_dir: u32,
        old_name: &'a [u8],
        new_dir: u32,
        new_name: &'a [u8],
    },
    Unlinkat {
        dir: u32,
        name: &'a [u8],
        flags: u32,
    },
    Statfs {
        fid: u32,
    },
    Fsync {
        fid: u32,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub enum R {
    Lerror(u32),
    Version { msize: u32, version: String },
    Attach(Qid),
    Walk(Vec<Qid>),
    Getattr(Attr),
    Setattr,
    Lopen(Qid),
    Lcreate(Qid),
    Read(Vec<u8>),
    Write(u32),
    Clunk,
    Readdir(Vec<Dirent>),
    Mkdir(Qid),
    Renameat,
    Unlinkat,
    Statfs(Statfs),
    Fsync,
}

#[derive(Debug, PartialEq, Eq)]
pub struct BadMessage(pub u8);

impl fmt::Display for BadMessage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "a 9P message of type {} that does not parse", self.0)
    }
}

struct Out(Vec<u8>);

impl Out {
    fn u8(&mut self, v: u8) -> &mut Self {
        self.0.push(v);
        self
    }
    fn u16(&mut self, v: u16) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    fn u32(&mut self, v: u32) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    fn u64(&mut self, v: u64) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    fn s(&mut self, v: &[u8]) -> &mut Self {
        self.u16(v.len() as u16);
        self.0.extend_from_slice(v);
        self
    }
    fn time(&mut self, t: Option<Option<Time>>) -> &mut Self {
        let t = t.flatten().unwrap_or_default();
        self.u64(t.sec).u64(t.nsec)
    }
}

impl T<'_> {
    fn kind(&self) -> u8 {
        match self {
            T::Statfs { .. } => 8,
            T::Lopen { .. } => 12,
            T::Lcreate { .. } => 14,
            T::Getattr { .. } => 24,
            T::Setattr { .. } => 26,
            T::Readdir { .. } => 40,
            T::Fsync { .. } => 50,
            T::Mkdir { .. } => 72,
            T::Renameat { .. } => 74,
            T::Unlinkat { .. } => 76,
            T::Version { .. } => 100,
            T::Attach { .. } => 104,
            T::Walk { .. } => 110,
            T::Read { .. } => 116,
            T::Write { .. } => 118,
            T::Clunk { .. } => 120,
        }
    }

    /// The whole message for `tag`.
    pub fn encode(&self, tag: u16) -> Vec<u8> {
        let mut o = Out(vec![0; 4]);
        o.u8(self.kind()).u16(tag);
        match *self {
            T::Version { msize } => {
                o.u32(msize).s(VERSION.as_bytes());
            }
            T::Attach { fid, n_uname } => {
                o.u32(fid).u32(NOFID).s(b"").s(b"").u32(n_uname);
            }
            T::Walk { fid, newfid, names } => {
                o.u32(fid).u32(newfid).u16(names.len() as u16);
                for name in names {
                    o.s(name);
                }
            }
            T::Getattr { fid } => {
                o.u32(fid).u64(GETATTR_BASIC);
            }
            T::Setattr { fid, set } => {
                use setattr::*;
                let mut valid = 0;
                let mut bit = |on: bool, b: u32| {
                    if on {
                        valid |= b
                    }
                };
                bit(set.mode.is_some(), MODE);
                bit(set.uid.is_some(), UID);
                bit(set.gid.is_some(), GID);
                bit(set.size.is_some(), SIZE);
                bit(set.atime.is_some(), ATIME);
                bit(matches!(set.atime, Some(Some(_))), ATIME_SET);
                bit(set.mtime.is_some(), MTIME);
                bit(matches!(set.mtime, Some(Some(_))), MTIME_SET);
                o.u32(fid)
                    .u32(valid)
                    .u32(set.mode.unwrap_or(0))
                    .u32(set.uid.unwrap_or(0))
                    .u32(set.gid.unwrap_or(0))
                    .u64(set.size.unwrap_or(0))
                    .time(set.atime)
                    .time(set.mtime);
            }
            T::Lopen { fid, flags } => {
                o.u32(fid).u32(flags);
            }
            T::Lcreate {
                fid,
                name,
                flags,
                mode,
                gid,
            } => {
                o.u32(fid).s(name).u32(flags).u32(mode).u32(gid);
            }
            T::Read { fid, offset, count } | T::Readdir { fid, offset, count } => {
                o.u32(fid).u64(offset).u32(count);
            }
            T::Write { fid, offset, data } => {
                o.u32(fid).u64(offset).u32(data.len() as u32);
                o.0.extend_from_slice(data);
            }
            T::Clunk { fid } | T::Statfs { fid } => {
                o.u32(fid);
            }
            T::Mkdir {
                fid,
                name,
                mode,
                gid,
            } => {
                o.u32(fid).s(name).u32(mode).u32(gid);
            }
            T::Renameat {
                old_dir,
                old_name,
                new_dir,
                new_name,
            } => {
                o.u32(old_dir).s(old_name).u32(new_dir).s(new_name);
            }
            T::Unlinkat { dir, name, flags } => {
                o.u32(dir).s(name).u32(flags);
            }
            T::Fsync { fid } => {
                o.u32(fid).u32(0);
            }
        }
        let size = o.0.len() as u32;
        o.0[..4].copy_from_slice(&size.to_le_bytes());
        o.0
    }
}

struct In<'a>(&'a [u8]);

impl<'a> In<'a> {
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        if self.0.len() < n {
            return None;
        }
        let (head, rest) = self.0.split_at(n);
        self.0 = rest;
        Some(head)
    }
    fn u8(&mut self) -> Option<u8> {
        self.take(1).map(|b| b[0])
    }
    fn u16(&mut self) -> Option<u16> {
        self.take(2)
            .map(|b| u16::from_le_bytes(b.try_into().unwrap()))
    }
    fn u32(&mut self) -> Option<u32> {
        self.take(4)
            .map(|b| u32::from_le_bytes(b.try_into().unwrap()))
    }
    fn u64(&mut self) -> Option<u64> {
        self.take(8)
            .map(|b| u64::from_le_bytes(b.try_into().unwrap()))
    }
    fn s(&mut self) -> Option<&'a [u8]> {
        let n = self.u16()? as usize;
        self.take(n)
    }
    fn qid(&mut self) -> Option<Qid> {
        Some(Qid {
            kind: self.u8()?,
            version: self.u32()?,
            path: self.u64()?,
        })
    }
    fn time(&mut self) -> Option<Time> {
        Some(Time {
            sec: self.u64()?,
            nsec: self.u64()?,
        })
    }
    fn end<T>(&self, value: T) -> Option<T> {
        self.0.is_empty().then_some(value)
    }
}

/// Decodes the body of the R-message of type `kind`.
pub fn decode(kind: u8, body: &[u8]) -> Result<R, BadMessage> {
    let mut i = In(body);
    let r = match kind {
        7 => i.u32().map(R::Lerror),
        101 => (|| {
            let msize = i.u32()?;
            let version = String::from_utf8(i.s()?.to_vec()).ok()?;
            Some(R::Version { msize, version })
        })(),
        105 => i.qid().map(R::Attach),
        111 => (|| {
            let n = i.u16()?;
            (0..n)
                .map(|_| i.qid())
                .collect::<Option<Vec<_>>>()
                .map(R::Walk)
        })(),
        25 => (|| {
            let _valid = i.u64()?;
            let qid = i.qid()?;
            let mode = i.u32()?;
            let (_uid, _gid) = (i.u32()?, i.u32()?);
            let nlink = i.u64()?;
            let _rdev = i.u64()?;
            let (size, blksize, blocks) = (i.u64()?, i.u64()?, i.u64()?);
            let (atime, mtime, ctime, _btime) = (i.time()?, i.time()?, i.time()?, i.time()?);
            let (_gen, _data_version) = (i.u64()?, i.u64()?);
            Some(R::Getattr(Attr {
                qid,
                mode,
                nlink,
                size,
                blksize,
                blocks,
                atime,
                mtime,
                ctime,
            }))
        })(),
        27 => Some(R::Setattr),
        13 | 15 => (|| {
            let qid = i.qid()?;
            let _iounit = i.u32()?;
            Some(if kind == 13 {
                R::Lopen(qid)
            } else {
                R::Lcreate(qid)
            })
        })(),
        117 => (|| {
            let n = i.u32()? as usize;
            i.take(n).map(|data| R::Read(data.to_vec()))
        })(),
        119 => i.u32().map(R::Write),
        121 => Some(R::Clunk),
        41 => (|| {
            let n = i.u32()? as usize;
            let mut entries = In(i.take(n)?);
            let mut out = Vec::new();
            while !entries.0.is_empty() {
                let qid = entries.qid()?;
                let offset = entries.u64()?;
                let kind = entries.u8()?;
                let name = entries.s()?.to_vec();
                out.push(Dirent {
                    qid,
                    offset,
                    kind,
                    name,
                });
            }
            Some(R::Readdir(out))
        })(),
        73 => i.qid().map(R::Mkdir),
        75 => Some(R::Renameat),
        77 => Some(R::Unlinkat),
        9 => (|| {
            Some(R::Statfs(Statfs {
                kind: i.u32()?,
                bsize: i.u32()?,
                blocks: i.u64()?,
                bfree: i.u64()?,
                bavail: i.u64()?,
                files: i.u64()?,
                ffree: i.u64()?,
                fsid: i.u64()?,
                namelen: i.u32()?,
            }))
        })(),
        51 => Some(R::Fsync),
        _ => None,
    };
    r.and_then(|r| i.end(r)).ok_or(BadMessage(kind))
}

/// The size, type and tag at the start of a message, when `header` is its first 7 bytes.
pub fn header(header: [u8; 7]) -> (u32, u8, u16) {
    let size = u32::from_le_bytes(header[..4].try_into().unwrap());
    (size, header[4], u16::from_le_bytes([header[5], header[6]]))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(kind: u8, tag: u16, body: &[u8]) -> Vec<u8> {
        let mut out = ((body.len() + 7) as u32).to_le_bytes().to_vec();
        out.push(kind);
        out.extend_from_slice(&tag.to_le_bytes());
        out.extend_from_slice(body);
        out
    }

    fn s(v: &[u8]) -> Vec<u8> {
        let mut out = (v.len() as u16).to_le_bytes().to_vec();
        out.extend_from_slice(v);
        out
    }

    const QID: [u8; 13] = [0x80, 3, 0, 0, 0, 42, 0, 0, 0, 0, 0, 0, 0];

    #[test]
    fn encodes_version_and_attach() {
        let mut body = 8192u32.to_le_bytes().to_vec();
        body.extend(s(b"9P2000.L"));
        assert_eq!(
            T::Version { msize: 8192 }.encode(NOTAG),
            frame(100, NOTAG, &body)
        );

        let mut body = 0u32.to_le_bytes().to_vec();
        body.extend(NOFID.to_le_bytes());
        body.extend(s(b""));
        body.extend(s(b""));
        body.extend(1000u32.to_le_bytes());
        assert_eq!(
            T::Attach {
                fid: 0,
                n_uname: 1000
            }
            .encode(1),
            frame(104, 1, &body)
        );
    }

    #[test]
    fn encodes_walk_names_in_order() {
        let names: &[&[u8]] = &[b"devbox", b"home"];
        let mut body = [1u32.to_le_bytes(), 2u32.to_le_bytes()].concat();
        body.extend(2u16.to_le_bytes());
        body.extend(s(b"devbox"));
        body.extend(s(b"home"));
        assert_eq!(
            T::Walk {
                fid: 1,
                newfid: 2,
                names
            }
            .encode(3),
            frame(110, 3, &body)
        );
    }

    #[test]
    fn encodes_setattr_with_only_what_it_sets() {
        let set = SetAttr {
            size: Some(3),
            mtime: Some(None),
            ..Default::default()
        };
        let bytes = T::Setattr { fid: 1, set }.encode(4);
        let valid = u32::from_le_bytes(bytes[11..15].try_into().unwrap());
        assert_eq!(valid, setattr::SIZE | setattr::MTIME);
        assert_eq!(u64::from_le_bytes(bytes[27..35].try_into().unwrap()), 3);
        assert_eq!(bytes.len(), 7 + 4 + 4 + 12 + 8 + 32);

        let set = SetAttr {
            atime: Some(Some(Time { sec: 9, nsec: 1 })),
            ..Default::default()
        };
        let bytes = T::Setattr { fid: 1, set }.encode(4);
        let valid = u32::from_le_bytes(bytes[11..15].try_into().unwrap());
        assert_eq!(valid, setattr::ATIME | setattr::ATIME_SET);
    }

    #[test]
    fn encodes_write_with_its_data() {
        let mut body = 1u32.to_le_bytes().to_vec();
        body.extend(5u64.to_le_bytes());
        body.extend(2u32.to_le_bytes());
        body.extend(b"hi");
        assert_eq!(
            T::Write {
                fid: 1,
                offset: 5,
                data: b"hi"
            }
            .encode(9),
            frame(118, 9, &body)
        );
    }

    #[test]
    fn decodes_replies() {
        assert_eq!(decode(7, &2u32.to_le_bytes()), Ok(R::Lerror(2)));
        assert_eq!(
            decode(105, &QID),
            Ok(R::Attach(Qid {
                kind: 0x80,
                version: 3,
                path: 42
            }))
        );

        let mut walk = 2u16.to_le_bytes().to_vec();
        walk.extend(QID);
        walk.extend(QID);
        assert!(matches!(decode(111, &walk), Ok(R::Walk(q)) if q.len() == 2));

        let mut read = 3u32.to_le_bytes().to_vec();
        read.extend(b"abc");
        assert_eq!(decode(117, &read), Ok(R::Read(b"abc".to_vec())));
        assert_eq!(decode(121, &[]), Ok(R::Clunk));
    }

    #[test]
    fn decodes_getattr() {
        let mut body = GETATTR_BASIC.to_le_bytes().to_vec();
        body.extend([0, 2, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0]);
        body.extend(0o100644u32.to_le_bytes());
        body.extend([1000u32.to_le_bytes(), 1000u32.to_le_bytes()].concat());
        for v in [1u64, 0, 513, 4096, 2, 10, 0, 20, 0, 30, 0, 0, 0, 0, 0] {
            body.extend(v.to_le_bytes());
        }
        let Ok(R::Getattr(attr)) = decode(25, &body) else {
            panic!("no getattr")
        };
        assert_eq!(attr.qid.path, 5);
        assert_eq!(attr.mode, 0o100644);
        assert_eq!(attr.size, 513);
        assert_eq!(attr.mtime, Time { sec: 20, nsec: 0 });
        assert_eq!(attr.ctime.sec, 30);
    }

    #[test]
    fn decodes_readdir_entries() {
        let mut entries = QID.to_vec();
        entries.extend(1u64.to_le_bytes());
        entries.push(4);
        entries.extend(s(b"src"));
        let mut body = (entries.len() as u32).to_le_bytes().to_vec();
        body.extend(entries);
        let Ok(R::Readdir(list)) = decode(41, &body) else {
            panic!("no readdir")
        };
        assert_eq!(list.len(), 1);
        assert_eq!(
            (list[0].offset, list[0].kind, list[0].name.as_slice()),
            (1, 4, &b"src"[..])
        );
    }

    #[test]
    fn a_short_or_long_reply_is_bad() {
        assert_eq!(decode(7, &[1, 0]), Err(BadMessage(7)));
        assert_eq!(decode(121, &[0]), Err(BadMessage(121)));
        assert_eq!(decode(117, &[5, 0, 0, 0, b'a']), Err(BadMessage(117)));
        assert_eq!(decode(200, &[]), Err(BadMessage(200)));
    }

    #[test]
    fn reads_a_header() {
        assert_eq!(header([11, 0, 0, 0, 7, 3, 0]), (11, 7, 3));
    }
}
