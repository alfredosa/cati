use core::fmt;

use nix::fcntl::fcntl;
use nix::fcntl::FcntlArg;
use nix::fcntl::OFlag;

use std::error::Error;
use std::os::fd::RawFd;

use termios::tcsetattr;
use termios::Termios;
use termios::ECHO;
use termios::ICANON;
use termios::TCSANOW;
use termios::VMIN;
use termios::VTIME;

// The Errors to handle termios shananigans
#[derive(Debug)]
pub(crate) enum TerminalError {
    TCGettAttr,
    TCSetAttr,
}

impl fmt::Display for TerminalError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            TerminalError::TCSetAttr => write!(f, "Unable to set attributes"),
            TerminalError::TCGettAttr => write!(f, "Unable to get current attributes"),
        }
    }
}

impl Error for TerminalError {}

/// Set a file descriptor to non-blocking mode
pub fn set_nonblocking(fd: RawFd) -> nix::Result<OFlag> {
    let flags = fcntl(fd, FcntlArg::F_GETFL)?;
    let mut flag = OFlag::from_bits_truncate(flags);
    let original_flags = flag;

    flag.insert(OFlag::O_NONBLOCK);

    fcntl(fd, FcntlArg::F_SETFL(flag))?;
    Ok(original_flags)
}

/// Restore the original flags to a file descriptor
pub fn restore_flags(fd: RawFd, flags: OFlag) -> nix::Result<()> {
    fcntl(fd, FcntlArg::F_SETFL(flags))?;
    Ok(())
}

pub fn restore_termios(fd: RawFd, t: Termios) -> Result<(), TerminalError> {
    tcsetattr(fd, TCSANOW, &t).map_err(|e| {
        println!("failed to set attrs. {}", e.to_string());
        TerminalError::TCSetAttr
    })?;

    Ok(())
}

/// .
///
/// # Errors
///
/// This function will return an error if .
pub fn set_termios_raw_mode(fd: RawFd) -> Result<Termios, TerminalError> {
    let termios = Termios::from_fd(fd).map_err(|e| {
        println!("failed to get attrs. {}", e.to_string());
        TerminalError::TCGettAttr
    })?;

    let mut raw_term = termios.clone();

    raw_term.c_lflag &= !(ICANON | ECHO);
    raw_term.c_cc[VMIN] = 0;
    raw_term.c_cc[VTIME] = 1;

    tcsetattr(fd, TCSANOW, &raw_term).map_err(|e| {
        println!("failed to set attrs. {}", e.to_string());
        TerminalError::TCSetAttr
    })?;

    Ok(termios)
}
