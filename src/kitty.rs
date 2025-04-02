use super::termios;

use std::{
    io::{stdin, stdout, Write},
    os::fd::{AsRawFd, BorrowedFd, RawFd},
    path,
};

use log::{debug, error, info};
use nix::sys::{
    select::{select, FdSet},
    time::{TimeVal, TimeValLike},
};
use nix::unistd::read;
use std::{thread, time};

pub enum Images {
    JPEG,
    PNG,
}

fn print_png() {
    debug!("printing png");
}
pub fn print_image(i: Images, path: &path::Path) -> Result<(), String> {
    match i {
        Images::PNG => {
            print_png();
        }
        _ => unreachable!("unimplemented image type"),
    }
    Ok(())
}

/// Safely insert a RawFd into an FdSet
fn insert_fd_into_set(fd_set: &mut FdSet, fd: RawFd) -> bool {
    if fd < 0 {
        return false; // Invalid file descriptor
    }

    // This is safe because we've checked that fd is valid and
    // the BorrowedFd will only exist for the duration of this function call
    unsafe {
        fd_set.insert(BorrowedFd::borrow_raw(fd));
    }
    true
}

/// Read from a file descriptor with timeout
fn read_with_timeout(fd: RawFd, buf: &mut [u8], timeout_ms: i64) -> nix::Result<Option<usize>> {
    let mut readfds = FdSet::new();
    if !insert_fd_into_set(&mut readfds, fd) {
        return Err(nix::Error::EBADF);
    }

    let mut timeout = TimeVal::milliseconds(timeout_ms);

    match select(
        Some(fd + 1),
        Some(&mut readfds),
        None,
        None,
        Some(&mut timeout),
    ) {
        Ok(result) => {
            if result > 0 {
                match read(fd, buf) {
                    Ok(bytes_read) => Ok(Some(bytes_read)),
                    Err(e) => {
                        use nix::errno::Errno;
                        if e == Errno::EAGAIN || e == Errno::EWOULDBLOCK {
                            // Sleep for 10ms and indicate no data available yet
                            thread::sleep(time::Duration::from_millis(10));
                            Ok(None)
                        } else {
                            Err(e)
                        }
                    }
                }
            } else {
                // Timeout or no data
                Ok(None)
            }
        }
        Err(e) => Err(e),
    }
}

pub fn is_kitty_protocol_supported() -> bool {
    let stdin_fd = stdin().as_raw_fd();

    let mut supports_kitty = false;

    // First we need to set the terminal to raw mode
    if let Ok(original_termios) = termios::set_termios_raw_mode(stdin_fd) {
        // Set stdin to non-blocking mode
        if let Ok(original_flags) = termios::set_nonblocking(stdin_fd) {
            // Send query sequence for Kitty graphics protocol
            let query = b"\x1B_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1B\\";

            let mut stdout_handle = stdout();
            if let Err(e) = stdout_handle.write_all(query) {
                error!("Failed to write to stdout: {e}");
            }
            // Flush stdout (equivalent to fflush(stdout) in C)
            if let Err(e) = stdout_handle.flush() {
                error!("Failed to flush stdout: {e}");
            }

            // Buffer to store response
            let mut buf = [0u8; 256];
            let mut total_read = 0;

            // Initial timeout: 500ms
            let mut timeout_ms = 500;

            // Continue reading until timeout or buffer full
            'read_loop: loop {
                let curr_len = buf.len();
                match read_with_timeout(
                    stdin_fd,
                    &mut buf[total_read..curr_len - total_read - 1],
                    timeout_ms,
                ) {
                    Ok(Some(bytes_read)) => {
                        if bytes_read == 0 {
                            break; // EOF
                        }

                        total_read += bytes_read;

                        // Search for protocol markers
                        for i in 0..total_read.saturating_sub(3) {
                            // Check for _Gi pattern
                            if buf[i] == b'_' && buf[i + 1] == b'G' && buf[i + 2] == b'i' {
                                supports_kitty = true;
                                break 'read_loop;
                            }
                        }

                        // If buffer is full or we've got a complete response
                        if total_read >= buf.len() - 1 {
                            break;
                        }

                        // Shorter timeout for subsequent reads
                        timeout_ms = 50;
                    }
                    Ok(None) => {
                        // Timeout occurred
                        break;
                    }
                    Err(e) => {
                        error!("Error reading from stdin: {}", e);
                        break;
                    }
                }
            }

            // Drain any remaining input before restoring terminal
            use nix::unistd::read;
            let mut drain_buf = [0u8; 256];
            loop {
                match read(stdin_fd, &mut drain_buf) {
                    Ok(bytes_read) if bytes_read > 0 => continue,
                    _ => break,
                }
            }

            // Restore original flags
            if let Err(e) = termios::restore_flags(stdin_fd, original_flags) {
                error!("Failed to restore flags: {}", e);
            }
        } else {
            error!("Failed to set non-blocking mode");
        }

        // Restore original terminal settings
        if let Err(e) = termios::restore_termios(stdin_fd, original_termios) {
            error!("Failed to restore terminal settings: {}", e);
        }
    } else {
        error!("Failed to set terminal to raw mode");
        return false;
    }

    supports_kitty
}
