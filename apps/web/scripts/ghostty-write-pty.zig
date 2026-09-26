extern "env" fn hal_c2_write_pty(terminal: u32, userdata: u32, data: u32, len: u32) void;

export fn ghostty_write_pty(terminal: u32, userdata: u32, data: u32, len: u32) void {
    hal_c2_write_pty(terminal, userdata, data, len);
}
