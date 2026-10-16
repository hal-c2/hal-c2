defmodule HalC2.MachineFiles.NineP do
  @moduledoc """
  The part of 9P2000.L the machine-files helper speaks (native/machine-files):
  T-messages decoded from it, R-messages encoded for it. A message is
  `size[4] type[1] tag[2] body`, little-endian, `size` counting itself; a string
  is `len[2]` and its bytes; a qid is `type[1] version[4] path[8]`.
  """

  import Bitwise

  @version "9P2000.L"

  @t %{
    8 => :statfs,
    12 => :lopen,
    14 => :lcreate,
    24 => :getattr,
    26 => :setattr,
    40 => :readdir,
    50 => :fsync,
    72 => :mkdir,
    74 => :renameat,
    76 => :unlinkat,
    100 => :version,
    104 => :attach,
    108 => :flush,
    110 => :walk,
    116 => :read,
    118 => :write,
    120 => :clunk
  }

  @r %{
    lerror: 7,
    statfs: 9,
    lopen: 13,
    lcreate: 15,
    getattr: 25,
    setattr: 27,
    readdir: 41,
    fsync: 51,
    mkdir: 73,
    renameat: 75,
    unlinkat: 77,
    version: 101,
    attach: 105,
    flush: 109,
    walk: 111,
    read: 117,
    write: 119,
    clunk: 121
  }

  # Rgetattr's `valid`: the basic fields (P9_GETATTR_BASIC).
  @getattr_basic 0x7FF
  # The bytes of an Rread or Rreaddir before its data: size, type, tag, count.
  @read_header 11

  @doc "The protocol version spoken."
  def version, do: @version

  @doc "The bytes before an Rread's or Rreaddir's data."
  def read_header, do: @read_header

  @doc "Splits whole messages off `buffer`: `{[{type, tag, body}], rest}`."
  @spec frames(binary) :: {[{non_neg_integer, non_neg_integer, binary}], binary}
  def frames(buffer), do: frames(buffer, [])

  defp frames(<<size::32-little, rest::binary>>, acc)
       when size >= 7 and byte_size(rest) >= size - 4 do
    body_size = size - 7
    <<type, tag::16-little, body::binary-size(^body_size), rest::binary>> = rest
    frames(rest, [{type, tag, body} | acc])
  end

  defp frames(buffer, acc), do: {Enum.reverse(acc), buffer}

  @doc "A frame's size field: whether a buffer starting with it can ever be a message."
  def valid_size?(<<size::32-little, _::binary>>, max), do: size >= 7 and size <= max
  def valid_size?(_partial, _max), do: true

  @doc """
  Decodes a T-message body: a tuple named after it, or `{:unknown, type}` for one
  this server does not answer, or `{:bad, type}` for one that does not parse.
  """
  @spec decode(non_neg_integer, binary) :: tuple
  def decode(type, body) do
    case Map.fetch(@t, type) do
      {:ok, name} -> parse(name, body) || {:bad, type}
      :error -> {:unknown, type}
    end
  rescue
    _ in [MatchError, FunctionClauseError, ArgumentError] -> {:bad, type}
  end

  defp parse(:version, <<msize::32-little, rest::binary>>) do
    {version, ""} = string(rest)
    {:version, msize, version}
  end

  defp parse(:attach, <<fid::32-little, _afid::32-little, rest::binary>>) do
    {_uname, rest} = string(rest)
    {_aname, <<_n_uname::32-little>>} = string(rest)
    {:attach, fid}
  end

  defp parse(:flush, <<oldtag::16-little>>), do: {:flush, oldtag}

  defp parse(:walk, <<fid::32-little, newfid::32-little, n::16-little, rest::binary>>) do
    {names, ""} = strings(rest, n, [])
    {:walk, fid, newfid, names}
  end

  defp parse(:getattr, <<fid::32-little, _mask::64-little>>), do: {:getattr, fid}

  defp parse(
         :setattr,
         <<fid::32-little, valid::32-little, mode::32-little, uid::32-little, gid::32-little,
           size::64-little, atime::64-little, _atime_nsec::64-little, mtime::64-little,
           _mtime_nsec::64-little>>
       ) do
    {:setattr, fid,
     %{
       valid: valid,
       mode: mode,
       uid: uid,
       gid: gid,
       size: size,
       atime: atime,
       mtime: mtime
     }}
  end

  defp parse(:lopen, <<fid::32-little, flags::32-little>>), do: {:lopen, fid, flags}

  defp parse(:lcreate, <<fid::32-little, rest::binary>>) do
    {name, <<flags::32-little, mode::32-little, _gid::32-little>>} = string(rest)
    {:lcreate, fid, name, flags, mode}
  end

  defp parse(:read, <<fid::32-little, offset::64-little, count::32-little>>),
    do: {:read, fid, offset, count}

  defp parse(:write, <<fid::32-little, offset::64-little, count::32-little, data::binary>>)
       when byte_size(data) == count,
       do: {:write, fid, offset, data}

  defp parse(:clunk, <<fid::32-little>>), do: {:clunk, fid}

  defp parse(:readdir, <<fid::32-little, offset::64-little, count::32-little>>),
    do: {:readdir, fid, offset, count}

  defp parse(:mkdir, <<fid::32-little, rest::binary>>) do
    {name, <<mode::32-little, _gid::32-little>>} = string(rest)
    {:mkdir, fid, name, mode}
  end

  defp parse(:unlinkat, <<fid::32-little, rest::binary>>) do
    {name, <<flags::32-little>>} = string(rest)
    {:unlinkat, fid, name, flags}
  end

  defp parse(:renameat, <<old::32-little, rest::binary>>) do
    {old_name, <<new::32-little, rest::binary>>} = string(rest)
    {new_name, ""} = string(rest)
    {:renameat, old, old_name, new, new_name}
  end

  defp parse(:statfs, <<fid::32-little>>), do: {:statfs, fid}
  defp parse(:fsync, <<fid::32-little, _datasync::32-little>>), do: {:fsync, fid}
  defp parse(_name, _body), do: nil

  defp string(<<len::16-little, value::binary-size(len), rest::binary>>), do: {value, rest}

  defp strings(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp strings(rest, n, acc) do
    {value, rest} = string(rest)
    strings(rest, n - 1, [value | acc])
  end

  @doc """
  Encodes an R-message for `tag`. `reply` is `{name, ...}` as `decode/2` names its
  T-message, or `{:lerror, errno}`.
  """
  @spec encode(non_neg_integer, tuple) :: iodata
  def encode(tag, reply) do
    {name, body} = body(reply)
    body = IO.iodata_to_binary(body)
    [<<byte_size(body) + 7::32-little, Map.fetch!(@r, name), tag::16-little>>, body]
  end

  defp body({:lerror, errno}), do: {:lerror, <<errno::32-little>>}
  defp body({:version, msize, version}), do: {:version, [<<msize::32-little>>, s(version)]}
  defp body({:attach, qid}), do: {:attach, qid(qid)}
  defp body({:flush}), do: {:flush, ""}
  defp body({:walk, qids}), do: {:walk, [<<length(qids)::16-little>> | Enum.map(qids, &qid/1)]}
  defp body({:lopen, qid, iounit}), do: {:lopen, [qid(qid), <<iounit::32-little>>]}
  defp body({:lcreate, qid, iounit}), do: {:lcreate, [qid(qid), <<iounit::32-little>>]}
  defp body({:read, data}), do: {:read, [<<byte_size(data)::32-little>>, data]}
  defp body({:write, count}), do: {:write, <<count::32-little>>}
  defp body({:clunk}), do: {:clunk, ""}
  defp body({:mkdir, qid}), do: {:mkdir, qid(qid)}
  defp body({:unlinkat}), do: {:unlinkat, ""}
  defp body({:renameat}), do: {:renameat, ""}
  defp body({:setattr}), do: {:setattr, ""}
  defp body({:fsync}), do: {:fsync, ""}

  defp body({:readdir, entries}) do
    data = IO.iodata_to_binary(Enum.map(entries, &dirent/1))
    {:readdir, [<<byte_size(data)::32-little>>, data]}
  end

  defp body({:statfs, %{} = fs}) do
    {:statfs,
     <<fs.type::32-little, fs.bsize::32-little, fs.blocks::64-little, fs.bfree::64-little,
       fs.bavail::64-little, fs.files::64-little, fs.ffree::64-little, fs.fsid::64-little,
       fs.namelen::32-little>>}
  end

  defp body({:getattr, qid, attr}) do
    blocks = div(attr.size + 511, 512)

    {:getattr,
     [
       <<@getattr_basic::64-little>>,
       qid(qid),
       <<attr.mode::32-little, attr.uid::32-little, attr.gid::32-little, attr.nlink::64-little,
         0::64-little, attr.size::64-little, 4096::64-little, blocks::64-little>>,
       time(attr.atime),
       time(attr.mtime),
       time(attr.ctime),
       time(0),
       <<0::64-little, 0::64-little>>
     ]}
  end

  @doc "The bytes a directory entry takes in an Rreaddir."
  def dirent_size({_qid, _offset, _type, name}), do: 13 + 8 + 1 + 2 + byte_size(name)

  defp dirent({qid, offset, type, name}),
    do: [qid(qid), <<offset::64-little, type>>, s(name)]

  @doc "A qid: `{type, version, path}`, `type` `:dir` or `:file`."
  def qid({type, version, path}),
    do: <<qid_type(type), band(version, 0xFFFFFFFF)::32-little, path::64-little>>

  defp qid_type(:dir), do: 0x80
  defp qid_type(:file), do: 0x00

  defp time(seconds) when is_integer(seconds) and seconds >= 0,
    do: <<seconds::64-little, 0::64-little>>

  defp time(_), do: <<0::64-little, 0::64-little>>

  defp s(value), do: [<<byte_size(value)::16-little>>, value]

  @errnos %{
    eperm: 1,
    enoent: 2,
    eio: 5,
    ebadf: 9,
    eacces: 13,
    eexist: 17,
    exdev: 18,
    enotdir: 20,
    eisdir: 21,
    einval: 22,
    efbig: 27,
    enospc: 28,
    erofs: 30,
    emlink: 31,
    enametoolong: 36,
    enosys: 38,
    enotempty: 39,
    eloop: 40,
    enotsup: 95,
    etimedout: 110,
    ehostdown: 112
  }

  @doc "The Linux errno of a POSIX error atom; EIO for one it does not know."
  def errno(reason), do: Map.get(@errnos, reason, 5)
end
