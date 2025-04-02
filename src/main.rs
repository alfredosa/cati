mod kitty;
mod termios;

use std::{env, error::Error};

use kitty::is_kitty_protocol_supported;
use log::{debug, error, info};

struct CLI {
    files: Vec<String>,
    // is the cli in ascii mode.
    ascii: bool,
}

impl CLI {
    pub fn parse() -> Result<Self, String> {
        let args: Vec<String> = env::args().collect();
        if args.len() < 2 {
            usage();
            return Err("Not enough arguments".to_string());
        }

        let ascii = args.contains(&"--ascii".to_string());

        // Get files (excluding program name and flags)
        let files: Vec<String> = args
            .iter()
            .skip(1) // Skip program name
            .filter(|arg| !arg.starts_with("--")) // Skip flags
            .cloned()
            .collect();

        if files.len() == 0 {
            usage();
            return Err("Not enough arguments".to_string());
        }
        Ok(CLI { ascii, files })
    }
}

fn run() -> Result<(), String> {
    let cli = CLI::parse()?; // Will return early if there's an error

    if cli.ascii {
        unreachable!("unimplemented feature!!")
    }

    let kgp = is_kitty_protocol_supported();
    debug!("terminal supports kitty graphics protocol: {kgp}");

    if !kgp {
        error!("the terminal doesn't support the kitty graphics protocol");
        info!("if you wanted to print in ascii, see usage");
        usage();
    }

    println!("Found {} files", cli.files.len());

    Ok(())
}

fn main() {
    // starting the logger so log (crate) works fine :) otherwise no output brosk.
    // without it, this ain't working at all.
    // TODO: how does OTEL work in rust?
    env_logger::init();

    if let Err(e) = run() {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

fn usage() {
    info!("cati (cat image):");
    info!("    --ascii: prints in ascii the image");
    info!("    <files>: list of files to print");
}
