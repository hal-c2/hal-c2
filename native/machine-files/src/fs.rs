//! The FUSE filesystem: each kernel request becomes 9P calls to the MC, which
//! decides what they mean. An inode is the qid path the MC gave it; each one the
//! kernel knows holds a fid until the kernel forgets it, and each open file or
//! directory holds a fid of its own (its handle) until it is released.
//!
//! An inode's fid is at the path the kernel last looked it up by. A symlink inside a
//! project and the file it names are one inode, so an older path may name another
//! file by now, or none: what reaches an inode by its fid checks it is still that
//! file, and fails as stale otherwise, which has the kernel look the name up again.
//!
//! A lookup may replace an inode's fid while another worker is about to send a
//! request on it, so each request holds the fid it uses (`Fid`), and a fid is
//! clunked once no node or request holds it.

use crate::client::Client;
use crate::p9::{AT_REMOVEDIR, Attr, R, SetAttr, T, Time};
use fuser::{
    AccessFlags, Errno, FileAttr, FileHandle, FileType, Filesystem, FopenFlags, Generation,
    INodeNo, KernelConfig, LockOwner, OpenFlags, RenameFlags, ReplyAttr, ReplyCreate, ReplyData,
    ReplyDirectory, ReplyEmpty, ReplyEntry, ReplyOpen, ReplyStatfs, ReplyWrite, Request, TimeOrNow,
    WriteFlags,
};
use std::collections::HashMap;
use std::ffi::OsStr;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const ROOT_FID: u32 = 0;
/// The most one write carries; the MC's msize leaves room for it.
const MAX_WRITE: u32 = 128 * 1024;
const READDIR_COUNT: u32 = 16 * 1024;

pub struct MachineFiles {
    client: Arc<Client>,
    ready: Arc<Ready>,
    ttl: Duration,
    uid: u32,
    gid: u32,
    nodes: Mutex<HashMap<u64, Node>>,
    next_fid: AtomicU32,
}

struct Node {
    fid: Arc<Fid>,
    lookups: u64,
}

/// A node's fid, clunked when the last holder lets go of it.
struct Fid {
    id: u32,
    client: Arc<Client>,
}

impl Drop for Fid {
    fn drop(&mut self) {
        let _ = self.client.call(&T::Clunk { fid: self.id });
    }
}

/// Set once the MC has attached the root; requests wait for it.
#[derive(Default)]
pub struct Ready {
    attached: Mutex<bool>,
    changed: Condvar,
}

impl Ready {
    pub fn set(&self) {
        *self.attached.lock().unwrap() = true;
        self.changed.notify_all();
    }

    fn wait(&self) {
        let mut attached = self.attached.lock().unwrap();
        while !*attached {
            attached = self.changed.wait(attached).unwrap();
        }
    }
}

type Result<T> = std::result::Result<T, Errno>;

fn errno(code: i32) -> Errno {
    Errno::from_i32(code)
}

/// An inode's path that names nothing now, or a fid a newer lookup replaced, is
/// stale: the kernel looks the name up again.
fn stale(e: Errno) -> Errno {
    if e == Errno::ENOENT || e == Errno::EBADF {
        Errno::ESTALE
    } else {
        e
    }
}

impl MachineFiles {
    pub fn new(client: Arc<Client>, ready: Arc<Ready>, ttl: Duration) -> MachineFiles {
        // SAFETY: getuid and getgid cannot fail and touch no memory.
        let (uid, gid) = unsafe { (libc::getuid(), libc::getgid()) };
        let mut nodes = HashMap::new();
        nodes.insert(
            INodeNo::ROOT.0,
            Node {
                fid: Arc::new(Fid {
                    id: ROOT_FID,
                    client: client.clone(),
                }),
                lookups: u64::MAX,
            },
        );
        MachineFiles {
            client,
            ready,
            ttl,
            uid,
            gid,
            nodes: Mutex::new(nodes),
            next_fid: AtomicU32::new(ROOT_FID + 1),
        }
    }

    fn call(&self, t: &T) -> Result<R> {
        self.ready.wait();
        self.client.call(t).map_err(errno)
    }

    /// The fid `ino` is reached by, held until the request using it is done.
    fn fid(&self, ino: INodeNo) -> Result<Arc<Fid>> {
        self.ready.wait();
        let nodes = self.nodes.lock().unwrap();
        nodes
            .get(&ino.0)
            .map(|node| node.fid.clone())
            .ok_or(Errno::ESTALE)
    }

    fn new_fid(&self) -> u32 {
        self.next_fid.fetch_add(1, Ordering::Relaxed)
    }

    fn clunk(&self, fid: u32) {
        let _ = self.client.call(&T::Clunk { fid });
    }

    /// A new fid at the same place as `fid`.
    fn clone_fid(&self, fid: u32) -> Result<u32> {
        let newfid = self.new_fid();
        self.call(&T::Walk {
            fid,
            newfid,
            names: &[],
        })?;
        Ok(newfid)
    }

    fn getattr_fid(&self, fid: u32) -> Result<Attr> {
        match self.call(&T::Getattr { fid })? {
            R::Getattr(attr) => Ok(attr),
            _ => Err(Errno::EIO),
        }
    }

    /// The fid `ino` is reached by and its attributes, if it is still that file.
    fn node_attr(&self, ino: INodeNo) -> Result<(Arc<Fid>, Attr)> {
        let fid = self.fid(ino)?;
        let attr = self.getattr_fid(fid.id).map_err(stale)?;
        if attr.qid.path == ino.0 {
            Ok((fid, attr))
        } else {
            Err(Errno::ESTALE)
        }
    }

    /// Looks `name` up in the directory `parent` and counts the lookup.
    fn lookup_entry(&self, parent: u32, name: &OsStr) -> Result<FileAttr> {
        let newfid = self.new_fid();
        let names: &[&[u8]] = &[name.as_bytes()];
        match self.call(&T::Walk {
            fid: parent,
            newfid,
            names,
        })? {
            R::Walk(qids) if qids.len() == 1 => {}
            _ => return Err(Errno::ENOENT),
        }
        let attr = match self.getattr_fid(newfid) {
            Ok(attr) => attr,
            Err(e) => {
                self.clunk(newfid);
                return Err(e);
            }
        };
        // The path just looked up names the file now; the one before may not. The
        // fid it replaces is clunked once the requests holding it are done.
        let fid = Arc::new(Fid {
            id: newfid,
            client: self.client.clone(),
        });
        let _replaced = {
            let mut nodes = self.nodes.lock().unwrap();
            match nodes.get_mut(&attr.qid.path) {
                Some(node) => {
                    node.lookups += 1;
                    Some(std::mem::replace(&mut node.fid, fid))
                }
                None => {
                    nodes.insert(attr.qid.path, Node { fid, lookups: 1 });
                    None
                }
            }
        };
        Ok(self.file_attr(&attr))
    }

    fn file_attr(&self, a: &Attr) -> FileAttr {
        let time = |t: Time| UNIX_EPOCH + Duration::new(t.sec, t.nsec.min(999_999_999) as u32);
        FileAttr {
            ino: INodeNo(a.qid.path),
            size: a.size,
            blocks: a.blocks,
            atime: time(a.atime),
            mtime: time(a.mtime),
            ctime: time(a.ctime),
            crtime: time(a.ctime),
            kind: kind(a.mode),
            perm: (a.mode & 0o7777) as u16,
            nlink: a.nlink.min(u32::MAX as u64) as u32,
            // The other machine's owners mean nothing here: this user has them all.
            uid: self.uid,
            gid: self.gid,
            rdev: 0,
            blksize: a.blksize.clamp(512, 1 << 20) as u32,
            flags: 0,
        }
    }

    fn open_fid(&self, ino: INodeNo, flags: OpenFlags) -> Result<u32> {
        let fid = self.clone_fid(self.fid(ino)?.id).map_err(stale)?;
        // Creating and truncating come as their own requests.
        let flags = flags.0 & !(libc::O_CREAT | libc::O_EXCL | libc::O_NOCTTY | libc::O_TRUNC);
        match self.call(&T::Lopen {
            fid,
            flags: flags as u32,
        }) {
            Ok(R::Lopen(qid)) if qid.path == ino.0 => Ok(fid),
            opened => {
                self.clunk(fid);
                Err(opened.map_or_else(stale, |_| Errno::ESTALE))
            }
        }
    }
}

fn kind(mode: u32) -> FileType {
    match mode & 0o170000 {
        0o040000 => FileType::Directory,
        0o120000 => FileType::Symlink,
        0o010000 => FileType::NamedPipe,
        0o020000 => FileType::CharDevice,
        0o060000 => FileType::BlockDevice,
        0o140000 => FileType::Socket,
        _ => FileType::RegularFile,
    }
}

fn dirent_kind(kind: u8) -> FileType {
    match kind {
        4 => FileType::Directory,
        10 => FileType::Symlink,
        _ => FileType::RegularFile,
    }
}

fn time(t: TimeOrNow) -> Option<Time> {
    match t {
        TimeOrNow::Now => None,
        TimeOrNow::SpecificTime(at) => {
            let since = at.duration_since(UNIX_EPOCH).unwrap_or_default();
            Some(Time {
                sec: since.as_secs(),
                nsec: since.subsec_nanos() as u64,
            })
        }
    }
}

impl Filesystem for MachineFiles {
    fn init(&mut self, _req: &Request, config: &mut KernelConfig) -> io::Result<()> {
        let _ = config.set_max_write(MAX_WRITE);
        Ok(())
    }

    fn lookup(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEntry) {
        match self
            .fid(parent)
            .and_then(|fid| self.lookup_entry(fid.id, name))
        {
            Ok(attr) => reply.entry(&self.ttl, &attr, Generation(0)),
            Err(e) => reply.error(e),
        }
    }

    fn forget(&self, _req: &Request, ino: INodeNo, nlookup: u64) {
        if ino == INodeNo::ROOT {
            return;
        }
        // Dropped, and so clunked once no request holds it, after the lock is let go.
        let _gone = {
            let mut nodes = self.nodes.lock().unwrap();
            match nodes.get_mut(&ino.0) {
                Some(node) if node.lookups > nlookup => {
                    node.lookups -= nlookup;
                    None
                }
                Some(_) => nodes.remove(&ino.0),
                None => None,
            }
        };
    }

    fn getattr(&self, _req: &Request, ino: INodeNo, fh: Option<FileHandle>, reply: ReplyAttr) {
        let attr = match fh {
            Some(fh) => self.getattr_fid(fh.0 as u32),
            None => self.node_attr(ino).map(|(_, attr)| attr),
        };
        match attr {
            Ok(attr) => reply.attr(&self.ttl, &self.file_attr(&attr)),
            Err(e) => reply.error(e),
        }
    }

    fn setattr(
        &self,
        _req: &Request,
        ino: INodeNo,
        mode: Option<u32>,
        uid: Option<u32>,
        gid: Option<u32>,
        size: Option<u64>,
        atime: Option<TimeOrNow>,
        mtime: Option<TimeOrNow>,
        _ctime: Option<SystemTime>,
        fh: Option<FileHandle>,
        _crtime: Option<SystemTime>,
        _chgtime: Option<SystemTime>,
        _bkuptime: Option<SystemTime>,
        _flags: Option<fuser::BsdFileFlags>,
        reply: ReplyAttr,
    ) {
        let set = SetAttr {
            mode,
            uid,
            gid,
            size,
            atime: atime.map(time),
            mtime: mtime.map(time),
        };
        // By the inode's path only while it names the same file, as truncate(2) asks.
        let (fid, _held) = match fh {
            Some(fh) => (fh.0 as u32, None),
            None => match self.node_attr(ino) {
                Ok((node, _)) => (node.id, Some(node)),
                Err(e) => return reply.error(e),
            },
        };
        let attr = self
            .call(&T::Setattr { fid, set })
            .and_then(|_| self.getattr_fid(fid));
        match attr {
            Ok(attr) => reply.attr(&self.ttl, &self.file_attr(&attr)),
            Err(e) => reply.error(e),
        }
    }

    fn mkdir(
        &self,
        _req: &Request,
        parent: INodeNo,
        name: &OsStr,
        mode: u32,
        umask: u32,
        reply: ReplyEntry,
    ) {
        let made = self.fid(parent).and_then(|dir| {
            let name = name.as_bytes();
            self.call(&T::Mkdir {
                fid: dir.id,
                name,
                mode: mode & !umask,
                gid: self.gid,
            })?;
            self.lookup_entry(dir.id, OsStr::from_bytes(name))
        });
        match made {
            Ok(attr) => reply.entry(&self.ttl, &attr, Generation(0)),
            Err(e) => reply.error(e),
        }
    }

    fn unlink(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
        let dir = self.fid(parent);
        let name = name.as_bytes();
        match dir.and_then(|dir| {
            self.call(&T::Unlinkat {
                dir: dir.id,
                name,
                flags: 0,
            })
        }) {
            Ok(_) => reply.ok(),
            Err(e) => reply.error(e),
        }
    }

    fn rmdir(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
        let dir = self.fid(parent);
        let name = name.as_bytes();
        match dir.and_then(|dir| {
            self.call(&T::Unlinkat {
                dir: dir.id,
                name,
                flags: AT_REMOVEDIR,
            })
        }) {
            Ok(_) => reply.ok(),
            Err(e) => reply.error(e),
        }
    }

    fn rename(
        &self,
        _req: &Request,
        parent: INodeNo,
        name: &OsStr,
        newparent: INodeNo,
        newname: &OsStr,
        flags: RenameFlags,
        reply: ReplyEmpty,
    ) {
        if !flags.is_empty() {
            return reply.error(Errno::EINVAL);
        }
        let renamed = self.fid(parent).and_then(|old_dir| {
            let new_dir = self.fid(newparent)?;
            self.call(&T::Renameat {
                old_dir: old_dir.id,
                old_name: name.as_bytes(),
                new_dir: new_dir.id,
                new_name: newname.as_bytes(),
            })
        });
        match renamed {
            Ok(_) => reply.ok(),
            Err(e) => reply.error(e),
        }
    }

    fn open(&self, _req: &Request, ino: INodeNo, flags: OpenFlags, reply: ReplyOpen) {
        match self.open_fid(ino, flags) {
            // No FOPEN_KEEP_CACHE: each open reads what the other machine has now.
            Ok(fid) => reply.opened(FileHandle(fid as u64), FopenFlags::empty()),
            Err(e) => reply.error(e),
        }
    }

    fn read(
        &self,
        _req: &Request,
        _ino: INodeNo,
        fh: FileHandle,
        offset: u64,
        size: u32,
        _flags: OpenFlags,
        _lock_owner: Option<LockOwner>,
        reply: ReplyData,
    ) {
        match self.call(&T::Read {
            fid: fh.0 as u32,
            offset,
            count: size,
        }) {
            Ok(R::Read(data)) => reply.data(&data),
            Ok(_) => reply.error(Errno::EIO),
            Err(e) => reply.error(e),
        }
    }

    fn write(
        &self,
        _req: &Request,
        _ino: INodeNo,
        fh: FileHandle,
        offset: u64,
        data: &[u8],
        _write_flags: WriteFlags,
        _flags: OpenFlags,
        _lock_owner: Option<LockOwner>,
        reply: ReplyWrite,
    ) {
        match self.call(&T::Write {
            fid: fh.0 as u32,
            offset,
            data,
        }) {
            Ok(R::Write(n)) => reply.written(n),
            Ok(_) => reply.error(Errno::EIO),
            Err(e) => reply.error(e),
        }
    }

    fn flush(
        &self,
        _req: &Request,
        _ino: INodeNo,
        _fh: FileHandle,
        _lock_owner: LockOwner,
        reply: ReplyEmpty,
    ) {
        // Every write went through to the other machine already.
        reply.ok();
    }

    fn release(
        &self,
        _req: &Request,
        _ino: INodeNo,
        fh: FileHandle,
        _flags: OpenFlags,
        _lock_owner: Option<LockOwner>,
        _flush: bool,
        reply: ReplyEmpty,
    ) {
        self.clunk(fh.0 as u32);
        reply.ok();
    }

    fn fsync(
        &self,
        _req: &Request,
        _ino: INodeNo,
        fh: FileHandle,
        _datasync: bool,
        reply: ReplyEmpty,
    ) {
        match self.call(&T::Fsync { fid: fh.0 as u32 }) {
            Ok(_) => reply.ok(),
            Err(e) => reply.error(e),
        }
    }

    fn opendir(&self, _req: &Request, ino: INodeNo, _flags: OpenFlags, reply: ReplyOpen) {
        match self.open_fid(ino, OpenFlags(libc::O_RDONLY)) {
            Ok(fid) => reply.opened(FileHandle(fid as u64), FopenFlags::empty()),
            Err(e) => reply.error(e),
        }
    }

    fn readdir(
        &self,
        _req: &Request,
        _ino: INodeNo,
        fh: FileHandle,
        offset: u64,
        mut reply: ReplyDirectory,
    ) {
        match self.call(&T::Readdir {
            fid: fh.0 as u32,
            offset,
            count: READDIR_COUNT,
        }) {
            Ok(R::Readdir(entries)) => {
                // What does not fit is asked for again from the last offset that did.
                for entry in entries {
                    let name = OsStr::from_bytes(&entry.name);
                    if reply.add(
                        INodeNo(entry.qid.path),
                        entry.offset,
                        dirent_kind(entry.kind),
                        name,
                    ) {
                        break;
                    }
                }
                reply.ok()
            }
            Ok(_) => reply.error(Errno::EIO),
            Err(e) => reply.error(e),
        }
    }

    fn releasedir(
        &self,
        _req: &Request,
        _ino: INodeNo,
        fh: FileHandle,
        _flags: OpenFlags,
        reply: ReplyEmpty,
    ) {
        self.clunk(fh.0 as u32);
        reply.ok();
    }

    fn statfs(&self, _req: &Request, ino: INodeNo, reply: ReplyStatfs) {
        match self
            .fid(ino)
            .and_then(|fid| self.call(&T::Statfs { fid: fid.id }))
        {
            Ok(R::Statfs(fs)) => reply.statfs(
                fs.blocks, fs.bfree, fs.bavail, fs.files, fs.ffree, fs.bsize, fs.namelen, fs.bsize,
            ),
            Ok(_) => reply.error(Errno::EIO),
            Err(e) => reply.error(e),
        }
    }

    fn access(&self, _req: &Request, _ino: INodeNo, _mask: AccessFlags, reply: ReplyEmpty) {
        // Only this user gets in (no allow_other); the other machine decides the rest.
        reply.ok();
    }

    fn create(
        &self,
        _req: &Request,
        parent: INodeNo,
        name: &OsStr,
        mode: u32,
        umask: u32,
        flags: i32,
        reply: ReplyCreate,
    ) {
        let created = self.fid(parent).and_then(|dir| {
            let fid = self.clone_fid(dir.id)?;
            let made = self.call(&T::Lcreate {
                fid,
                name: name.as_bytes(),
                flags: (flags & !libc::O_TRUNC) as u32,
                mode: mode & !umask,
                gid: self.gid,
            });
            match made.and_then(|_| self.lookup_entry(dir.id, name)) {
                Ok(attr) => Ok((fid, attr)),
                Err(e) => {
                    self.clunk(fid);
                    Err(e)
                }
            }
        });
        match created {
            Ok((fid, attr)) => reply.created(
                &self.ttl,
                &attr,
                Generation(0),
                FileHandle(fid as u64),
                FopenFlags::empty(),
            ),
            Err(e) => reply.error(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::p9;
    use std::io::{Read, Write};
    use std::os::unix::net::UnixStream;
    use std::sync::mpsc::{Receiver, Sender, TryRecvError, channel};
    use std::thread;

    const QID: [u8; 13] = [0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0];

    /// The filesystem, served by an MC whose every walk reaches file 5, and the
    /// fids it is told to clunk.
    fn served() -> (MachineFiles, Receiver<u32>) {
        let (ours, theirs) = UnixStream::pair().unwrap();
        let client = Arc::new(Client::new(Box::new(ours.try_clone().unwrap())));
        {
            let client = client.clone();
            thread::spawn(move || client.read_replies(ours));
        }
        let (clunks, clunked) = channel();
        thread::spawn(move || serve(theirs, clunks));
        let ready = Arc::new(Ready::default());
        ready.set();
        (MachineFiles::new(client, ready, Duration::ZERO), clunked)
    }

    fn serve(mut mc: UnixStream, clunks: Sender<u32>) {
        let mut head = [0u8; 7];
        while mc.read_exact(&mut head).is_ok() {
            let (size, kind, tag) = p9::header(head);
            let mut body = vec![0u8; size as usize - 7];
            mc.read_exact(&mut body).unwrap();
            let fid = u32::from_le_bytes(body[..4].try_into().unwrap());
            let (kind, reply) = match kind {
                110 => (111, [&1u16.to_le_bytes()[..], &QID].concat()),
                24 => {
                    let mut attr = [0u8; 8].to_vec();
                    attr.extend(QID);
                    attr.extend(0o100644u32.to_le_bytes());
                    attr.extend([0u8; 8]);
                    attr.extend([0u8; 15 * 8]);
                    (25, attr)
                }
                120 => {
                    clunks.send(fid).unwrap();
                    (121, Vec::new())
                }
                other => panic!("unexpected T-message {other}"),
            };
            let mut out = ((reply.len() + 7) as u32).to_le_bytes().to_vec();
            out.push(kind);
            out.extend(tag.to_le_bytes());
            out.extend(reply);
            mc.write_all(&out).unwrap();
        }
    }

    #[test]
    fn a_fid_a_request_holds_outlives_the_lookup_that_replaces_it() {
        let (fs, clunked) = served();
        fs.lookup_entry(ROOT_FID, OsStr::new("a")).unwrap();
        // A worker about to send a request on the inode's fid...
        let held = fs.fid(INodeNo(5)).unwrap();
        // ...while another looks the inode up again, as by another path.
        fs.lookup_entry(ROOT_FID, OsStr::new("a")).unwrap();
        assert_eq!(clunked.try_recv(), Err(TryRecvError::Empty));

        let id = held.id;
        drop(held);
        assert_eq!(clunked.try_recv(), Ok(id));
    }
}
