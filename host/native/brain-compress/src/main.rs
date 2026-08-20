// Stage 1 lands storage/ledger/util APIs that later stages consume; some are
// not yet called. Keep them without per-item noise.
#![allow(dead_code)]

//! brain-compress: native consultation, artifact, and accounting foundation for
//! claude-brain. One binary serves several applets, dispatched on argv[0] (via
//! the launchers' `exec -a`) and on a leading subcommand:
//!
//!   brain-ask ...            -> ask applet (drop-in for the Bash brain-ask)
//!   brain-compress ask ...   -> ask applet
//!   brain-compress <cmd> ... -> compress CLI (status/stats/savings/show/gc/doctor)
//!   brain compress <cmd> ... -> same CLI (the `compress` token is stripped)

mod artifact;
mod ask;
mod cli;
mod config;
mod files;
mod hook;
mod http;
mod ledger;
mod shell;
mod util;

use std::env;
use std::path::Path;

#[tokio::main]
async fn main() {
    // Restore default SIGPIPE so `brain compress show … | head` terminates
    // quietly like any Unix tool instead of panicking on a broken pipe (Rust
    // installs SIG_IGN by default, which turns a closed pipe into a write error
    // that println! then panics on).
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }

    let argv0 = env::args()
        .next()
        .and_then(|value| {
            Path::new(&value)
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
        })
        .unwrap_or_else(|| "brain-compress".to_string());

    let mut args: Vec<String> = env::args().skip(1).collect();

    let exit_code = if argv0 == "brain-ask" {
        ask::run(args).await
    } else if matches!(
        args.first().map(String::as_str),
        Some("ask") | Some("brain-ask")
    ) {
        args.remove(0);
        ask::run(args).await
    } else if matches!(args.first().map(String::as_str), Some("shell")) {
        args.remove(0);
        shell::run(args).await
    } else if matches!(args.first().map(String::as_str), Some("hook")) {
        args.remove(0);
        hook::run(args).await
    } else {
        if matches!(args.first().map(String::as_str), Some("compress")) {
            args.remove(0);
        }
        cli::run(args).await
    };

    std::process::exit(exit_code);
}
