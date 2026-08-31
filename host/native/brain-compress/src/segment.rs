//! Quote-aware splitting of a Bash command line into individual commands.
//!
//! The PreToolUse hook used to veto any command containing a shell
//! metacharacter, which meant real agent traffic (overwhelmingly
//! `cd x && git log`, `a; b`, `cmd | head`) was never compressed: a replay of
//! 1336 recorded Bash calls found exactly ONE eligible command. This module
//! replaces that whole-string veto with a scan that finds the individual
//! commands and lets the caller rewrite only the ones it understands.
//!
//! The scanner is deliberately partial. It recognises quoting, escaping and the
//! separators `&&`, `||`, `;`, `|`; anything that changes *where output goes* or
//! *what gets run* (redirects, command substitution, subshells, backgrounding,
//! newlines/heredocs) makes the whole command `Unsupported` and the caller
//! leaves it alone. That is the safe direction to be wrong in: a missed
//! compression costs tokens, a bad rewrite costs correctness.

/// One command inside a command line, with the byte offsets it occupies in the
/// original string so the caller can splice a prefix in without reformatting.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Segment {
    /// Byte offset of the first non-blank byte of this command.
    pub start: usize,
    /// Byte offset just past the last byte of this command.
    pub end: usize,
    /// How many commands are in the pipeline this one belongs to.
    pub pipeline_len: usize,
    /// This command's position within its pipeline (0-based).
    pub pipeline_index: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Split {
    /// The command contains a construct the scanner will not reason about.
    Unsupported,
    /// The commands found, in source order.
    Commands(Vec<Segment>),
}

/// Split `command` into its individual commands, or report `Unsupported`.
pub fn split(command: &str) -> Split {
    let bytes = command.as_bytes();
    // (offset of separator, is_pipeline_separator)
    let mut breaks: Vec<(usize, usize, bool)> = Vec::new();
    let mut i = 0usize;
    let mut in_single = false;
    let mut in_double = false;

    while i < bytes.len() {
        let c = bytes[i];

        if in_single {
            // Inside '…' nothing is special except the closing quote — not even
            // a backslash.
            if c == b'\'' {
                in_single = false;
            }
            i += 1;
            continue;
        }

        if c == b'\\' {
            // A backslash escapes the next byte in both unquoted and "…" text.
            i += 2;
            continue;
        }

        if in_double {
            if c == b'"' {
                in_double = false;
                i += 1;
                continue;
            }
            // Command substitution inside "…" still runs a command.
            if c == b'$' && bytes.get(i + 1) == Some(&b'(') {
                return Split::Unsupported;
            }
            if c == b'`' {
                return Split::Unsupported;
            }
            i += 1;
            continue;
        }

        match c {
            b'\'' => in_single = true,
            b'"' => in_double = true,
            // Newlines mean heredocs, loops, or multi-line scripts. Out of scope.
            b'\n' | b'\r' => return Split::Unsupported,
            // Redirects move stdout/stdin somewhere we cannot see.
            b'<' | b'>' => return Split::Unsupported,
            // Subshells and process substitution.
            b'(' | b')' => return Split::Unsupported,
            b'`' => return Split::Unsupported,
            b'$' if bytes.get(i + 1) == Some(&b'(') => return Split::Unsupported,
            b';' => breaks.push((i, 1, false)),
            b'&' => {
                if bytes.get(i + 1) == Some(&b'&') {
                    breaks.push((i, 2, false));
                    i += 2;
                    continue;
                }
                // A lone `&` backgrounds the command.
                return Split::Unsupported;
            }
            b'|' => {
                if bytes.get(i + 1) == Some(&b'|') {
                    breaks.push((i, 2, false));
                    i += 2;
                    continue;
                }
                breaks.push((i, 1, true));
            }
            _ => {}
        }
        i += 1;
    }

    if in_single || in_double {
        return Split::Unsupported; // unterminated quote: we misread something
    }

    // Cut the line at the separators, remembering which cuts were pipes so we
    // can tell how long each pipeline is.
    let mut pieces: Vec<(usize, usize, bool)> = Vec::new(); // (start, end, piped_into_next)
    let mut cursor = 0usize;
    for (offset, width, is_pipe) in &breaks {
        pieces.push((cursor, *offset, *is_pipe));
        cursor = offset + width;
    }
    pieces.push((cursor, command.len(), false));

    // Group consecutive pipe-joined pieces into pipelines.
    let mut out: Vec<Segment> = Vec::new();
    let mut group: Vec<(usize, usize)> = Vec::new();
    for (start, end, piped) in pieces {
        let (s, e) = trim_range(command, start, end);
        group.push((s, e));
        if !piped {
            let len = group.len();
            for (index, (gs, ge)) in group.drain(..).enumerate() {
                out.push(Segment {
                    start: gs,
                    end: ge,
                    pipeline_len: len,
                    pipeline_index: index,
                });
            }
        }
    }
    // `group` is always drained above because the final piece has piped=false.
    debug_assert!(group.is_empty());

    Split::Commands(out)
}

/// Narrow `start..end` to the non-whitespace content inside it.
fn trim_range(command: &str, start: usize, end: usize) -> (usize, usize) {
    let bytes = command.as_bytes();
    let mut s = start;
    let mut e = end;
    while s < e && (bytes[s] as char).is_whitespace() {
        s += 1;
    }
    while e > s && (bytes[e - 1] as char).is_whitespace() {
        e -= 1;
    }
    (s, e)
}

/// The argv-style words of a segment, for filter lookup. Returns None when the
/// segment starts with something we should not treat as a plain command: an
/// environment assignment (`FOO=bar cmd`), or a quoted/substituted first word.
pub fn words(text: &str) -> Option<Vec<String>> {
    let mut words: Vec<String> = Vec::new();
    for raw in text.split_whitespace() {
        words.push(raw.to_string());
    }
    let first = words.first()?;
    if first.contains('\'') || first.contains('"') || first.contains('$') {
        return None;
    }
    // `FOO=bar cmd …` runs `cmd`, not `FOO=bar`. Rather than model the prefix,
    // decline: these are rare and always safe to skip.
    if first.contains('=') {
        return None;
    }
    // Normalise `/usr/bin/git` to `git` so an absolute path still matches.
    if let Some(base) = first.rsplit('/').next() {
        if !base.is_empty() {
            let base = base.to_string();
            words[0] = base;
        }
    }
    Some(words)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parts(command: &str) -> Vec<(String, usize, usize)> {
        match split(command) {
            Split::Commands(segments) => segments
                .into_iter()
                .map(|s| {
                    (
                        command[s.start..s.end].to_string(),
                        s.pipeline_len,
                        s.pipeline_index,
                    )
                })
                .collect(),
            Split::Unsupported => panic!("expected supported: {command}"),
        }
    }

    #[test]
    fn plain_command_is_one_segment() {
        assert_eq!(parts("git log"), vec![("git log".into(), 1, 0)]);
    }

    #[test]
    fn and_or_and_semicolon_separate_statements() {
        assert_eq!(
            parts("cd /tmp && git log"),
            vec![("cd /tmp".into(), 1, 0), ("git log".into(), 1, 0)]
        );
        assert_eq!(
            parts("a; b || c"),
            vec![("a".into(), 1, 0), ("b".into(), 1, 0), ("c".into(), 1, 0)]
        );
    }

    #[test]
    fn pipelines_record_their_length_and_position() {
        assert_eq!(
            parts("git log | head -5"),
            vec![("git log".into(), 2, 0), ("head -5".into(), 2, 1)]
        );
        // A pipeline inside a longer statement list keeps its own grouping.
        assert_eq!(
            parts("cd x && a | b && c"),
            vec![
                ("cd x".into(), 1, 0),
                ("a".into(), 2, 0),
                ("b".into(), 2, 1),
                ("c".into(), 1, 0),
            ]
        );
    }

    #[test]
    fn separators_inside_quotes_are_not_separators() {
        assert_eq!(
            parts("grep -n 'a && b' src"),
            vec![("grep -n 'a && b' src".into(), 1, 0)]
        );
        assert_eq!(
            parts("grep -n \"a | b\" src"),
            vec![("grep -n \"a | b\" src".into(), 1, 0)]
        );
        assert_eq!(parts("grep -n a\\;b src"), vec![("grep -n a\\;b src".into(), 1, 0)]);
    }

    #[test]
    fn offsets_map_back_to_the_original_text() {
        let command = "cd /tmp   &&   git log --oneline";
        let segments = match split(command) {
            Split::Commands(s) => s,
            Split::Unsupported => panic!("supported"),
        };
        assert_eq!(&command[segments[1].start..segments[1].end], "git log --oneline");
    }

    #[test]
    fn output_moving_and_code_running_constructs_are_unsupported() {
        for command in [
            "git log > out.txt",
            "git log 2>&1",
            "cat < in.txt",
            "echo $(whoami)",
            "echo `whoami`",
            "(cd x && git log)",
            "git log &",
            "git log\nrm -rf /",
            "echo \"$(id)\"",
            "grep 'unterminated",
        ] {
            assert_eq!(split(command), Split::Unsupported, "{command}");
        }
    }

    #[test]
    fn words_normalises_paths_and_declines_prefixes() {
        assert_eq!(words("/usr/bin/git log").unwrap()[0], "git");
        assert_eq!(words("git log -20").unwrap(), vec!["git", "log", "-20"]);
        assert!(words("FOO=bar git log").is_none());
        assert!(words("$TOOL log").is_none());
        assert!(words("").is_none());
    }
}
