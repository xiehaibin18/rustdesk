#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CliExit {
    pub(crate) status: i32,
    pub(crate) stdout: String,
    pub(crate) stderr: String,
}

const METADATA_USAGE: &str = "Usage: RustDesk-Herbin --help [terminal|file-transfer]\n";
const CAPABILITIES: &str = "headless-terminal\nheadless-file-transfer\n";

fn success(stdout: String) -> CliExit {
    CliExit {
        status: 0,
        stdout,
        stderr: String::new(),
    }
}

fn usage_error(message: &str) -> CliExit {
    CliExit {
        status: 2,
        stdout: String::new(),
        stderr: format!("{message}\n{METADATA_USAGE}"),
    }
}

fn general_help() -> String {
    format!(
        concat!(
            "RustDesk-Herbin CLI\n\n",
            "Usage:\n",
            "  RustDesk-Herbin --help [terminal|file-transfer]\n",
            "  RustDesk-Herbin --version\n",
            "  RustDesk-Herbin --capabilities\n",
            "  {}\n",
            "  {}\n\n",
            "Run --help terminal or --help file-transfer for command details.\n"
        ),
        crate::headless_terminal::usage(),
        crate::headless_file_transfer::usage()
    )
}

fn terminal_help() -> String {
    format!(
        concat!(
            "{}\n\n",
            "Open an interactive macOS controller-side terminal without Flutter.\n",
            "Use --relay to force relay transport and --persistent to detach without closing the remote terminal.\n",
            "The peer ID must not contain whitespace. Plaintext --password arguments are rejected.\n"
        ),
        crate::headless_terminal::usage()
    )
}

fn file_transfer_help() -> String {
    format!(
        concat!(
            "{}\n\n",
            "Transfer exactly one regular file from a macOS controller through the native RustDesk file-transfer channel.\n",
            "For push, source is local and destination is remote; pull reverses those roles.\n",
            "Existing destinations require --overwrite. Plaintext --password arguments are rejected.\n"
        ),
        crate::headless_file_transfer::usage()
    )
}

pub(crate) fn classify_metadata(
    args: &[String],
    upstream_version: &str,
    rdh_revision: &str,
) -> Option<CliExit> {
    let command = args.first()?.as_str();
    match command {
        "--help" => Some(match args.get(1).map(String::as_str) {
            None if args.len() == 1 => success(general_help()),
            Some("terminal") if args.len() == 2 => success(terminal_help()),
            Some("file-transfer") if args.len() == 2 => success(file_transfer_help()),
            Some(topic) if args.len() == 2 => {
                usage_error(&format!("unsupported help topic: {topic}"))
            }
            _ => usage_error("--help accepts at most one topic"),
        }),
        "--version" => Some(if args.len() == 1 {
            success(format!(
                "RustDesk-Herbin {upstream_version}-rdh.{rdh_revision}\n"
            ))
        } else {
            usage_error("--version accepts no arguments")
        }),
        "--capabilities" => Some(if args.len() == 1 {
            success(CAPABILITIES.to_owned())
        } else {
            usage_error("--capabilities accepts no arguments")
        }),
        _ => None,
    }
}

pub(crate) fn classify_current_metadata(args: &[String]) -> Option<CliExit> {
    let revision = option_env!("RDH_REVISION")
        .filter(|revision| !revision.is_empty())
        .unwrap_or("dev");
    classify_metadata(args, crate::VERSION, revision)
}

pub(crate) fn should_start_without_appkit(args: &[String]) -> bool {
    classify_current_metadata(args).is_some() || args.iter().any(|arg| arg == "--headless")
}

pub(crate) fn is_unsupported_headless(args: &[String]) -> bool {
    args.iter().any(|arg| arg == "--headless")
        && !crate::headless_terminal::is_requested(args)
        && !crate::headless_file_transfer::is_requested(args)
}

pub(crate) fn unsupported_headless_exit() -> CliExit {
    usage_error("unsupported headless command")
}

pub(crate) fn emit(exit: &CliExit) {
    if !exit.stdout.is_empty() {
        print!("{}", exit.stdout);
    }
    if !exit.stderr.is_empty() {
        eprint!("{}", exit.stderr);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    fn metadata(values: &[&str]) -> CliExit {
        classify_metadata(&args(values), "1.4.9", "20")
            .unwrap_or_else(|| panic!("metadata command was not claimed: {values:?}"))
    }

    #[test]
    fn renders_general_and_topic_help_without_stderr() {
        let general = metadata(&["--help"]);
        assert_eq!(general.status, 0);
        assert!(general.stderr.is_empty());
        for marker in [
            "RustDesk-Herbin CLI",
            "--help [terminal|file-transfer]",
            "--version",
            "--capabilities",
            "--terminal --headless",
            "--file-transfer --headless",
        ] {
            assert!(general.stdout.contains(marker), "missing {marker:?}");
        }

        let terminal = metadata(&["--help", "terminal"]);
        assert_eq!(terminal.status, 0);
        assert!(terminal.stderr.is_empty());
        assert!(terminal.stdout.contains(
            "Usage: RustDesk-Herbin --terminal --headless [--relay] [--persistent] <peer-id>"
        ));

        let file_transfer = metadata(&["--help", "file-transfer"]);
        assert_eq!(file_transfer.status, 0);
        assert!(file_transfer.stderr.is_empty());
        assert!(file_transfer.stdout.contains(
            "Usage: RustDesk-Herbin --file-transfer --headless [--relay] [--overwrite] <peer-id> <push|pull> <source-file> <destination-file>"
        ));
    }

    #[test]
    fn renders_revisioned_version_and_machine_readable_capabilities() {
        assert_eq!(
            metadata(&["--version"]),
            CliExit {
                status: 0,
                stdout: "RustDesk-Herbin 1.4.9-rdh.20\n".to_owned(),
                stderr: String::new(),
            }
        );
        assert_eq!(
            metadata(&["--capabilities"]),
            CliExit {
                status: 0,
                stdout: "headless-terminal\nheadless-file-transfer\n".to_owned(),
                stderr: String::new(),
            }
        );
    }

    #[test]
    fn rejects_invalid_metadata_shapes_without_stdout() {
        for values in [
            vec!["--help", "unknown"],
            vec!["--help", "terminal", "extra"],
            vec!["--version", "extra"],
            vec!["--capabilities", "extra"],
        ] {
            let result = metadata(&values);
            assert_eq!(result.status, 2, "unexpected result for {values:?}");
            assert!(result.stdout.is_empty());
            assert!(result.stderr.contains("Usage: RustDesk-Herbin --help"));
        }
    }

    #[test]
    fn starts_cli_before_appkit_for_metadata_and_every_headless_shape() {
        for values in [
            vec!["--help"],
            vec!["--version"],
            vec!["--capabilities"],
            vec!["--headless"],
            vec!["--terminal", "--headless", "175116438"],
            vec![
                "--file-transfer",
                "--headless",
                "175116438",
                "push",
                "a",
                "b",
            ],
        ] {
            assert!(
                should_start_without_appkit(&args(&values)),
                "CLI shape reached AppKit: {values:?}"
            );
        }

        assert!(!should_start_without_appkit(&[]));
        assert!(!should_start_without_appkit(&args(&[
            "--file-transfer",
            "175116438"
        ])));
    }

    #[test]
    fn rejects_only_unclaimed_headless_combinations() {
        assert!(is_unsupported_headless(&args(&["--headless"])));
        assert!(is_unsupported_headless(&args(&[
            "--connect",
            "--headless",
            "175116438"
        ])));
        assert!(!is_unsupported_headless(&args(&[
            "--terminal",
            "--headless",
            "175116438"
        ])));
        assert!(!is_unsupported_headless(&args(&[
            "--file-transfer",
            "--headless",
            "175116438",
            "push",
            "a",
            "b"
        ])));
    }
}
