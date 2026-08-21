//! brain-symbols — stateless tree-sitter helper for brain-compress.
//!
//! Contract (see docs/compression-improvements-design.md §1): file CONTENT on
//! stdin only — never paths, credentials, or instructions. JSON on stdout.
//! Exit ≠0 ⇒ the caller falls back to its lexical path.
//!
//!   brain-symbols defs --lang rust               < file.rs
//!   brain-symbols classify --lang rust --symbol NAME < file.rs
//!   brain-symbols langs

use std::io::Read;
use tree_sitter::{Language, Node, Parser};

const LANGS: &[&str] = &["rust", "python", "typescript", "javascript", "go", "bash"];

fn language(lang: &str) -> Option<Language> {
    match lang {
        "rust" => Some(tree_sitter_rust::LANGUAGE.into()),
        "python" => Some(tree_sitter_python::LANGUAGE.into()),
        "typescript" => Some(tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into()),
        "tsx" => Some(tree_sitter_typescript::LANGUAGE_TSX.into()),
        "javascript" => Some(tree_sitter_typescript::LANGUAGE_TSX.into()),
        "go" => Some(tree_sitter_go::LANGUAGE.into()),
        "bash" => Some(tree_sitter_bash::LANGUAGE.into()),
        _ => None,
    }
}

/// Node kinds that introduce a named definition, per language.
fn def_kinds(lang: &str) -> &'static [&'static str] {
    match lang {
        "rust" => &[
            "function_item", "struct_item", "enum_item", "trait_item", "impl_item",
            "mod_item", "const_item", "static_item", "type_item", "macro_definition",
        ],
        "python" => &["function_definition", "class_definition"],
        "typescript" | "tsx" | "javascript" => &[
            "function_declaration", "class_declaration", "method_definition",
            "interface_declaration", "enum_declaration", "type_alias_declaration",
            "lexical_declaration",
        ],
        "go" => &["function_declaration", "method_declaration", "type_declaration"],
        "bash" => &["function_definition"],
        _ => &[],
    }
}

fn main() {
    std::process::exit(run());
}

fn run() -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = args.first().map(String::as_str).unwrap_or("");

    if command == "langs" {
        println!("{}", serde_json::to_string(&LANGS).unwrap());
        return 0;
    }

    let mut lang = None;
    let mut symbol = None;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--lang" => {
                i += 1;
                lang = args.get(i).cloned();
            }
            "--symbol" => {
                i += 1;
                symbol = args.get(i).cloned();
            }
            other => {
                eprintln!("brain-symbols: unknown argument {other}");
                return 2;
            }
        }
        i += 1;
    }
    let Some(lang) = lang else {
        eprintln!("brain-symbols: --lang is required (see `brain-symbols langs`)");
        return 2;
    };
    let Some(language) = language(&lang) else {
        eprintln!("brain-symbols: unsupported language {lang}");
        return 2;
    };

    let mut source = Vec::new();
    if std::io::stdin().read_to_end(&mut source).is_err() {
        eprintln!("brain-symbols: cannot read stdin");
        return 2;
    }

    let mut parser = Parser::new();
    if parser.set_language(&language).is_err() {
        eprintln!("brain-symbols: grammar version mismatch for {lang}");
        return 2;
    }
    let Some(tree) = parser.parse(&source, None) else {
        eprintln!("brain-symbols: parse failed");
        return 2;
    };

    match command {
        "defs" => {
            let mut out = Vec::new();
            collect_defs(tree.root_node(), &source, def_kinds(&lang), &mut out);
            println!("{}", serde_json::to_string(&out).unwrap());
            0
        }
        "classify" => {
            let Some(symbol) = symbol else {
                eprintln!("brain-symbols: classify requires --symbol");
                return 2;
            };
            let mut out = Vec::new();
            classify(tree.root_node(), &source, &symbol, def_kinds(&lang), &mut out);
            println!("{}", serde_json::to_string(&out).unwrap());
            0
        }
        other => {
            eprintln!("brain-symbols: unknown command {other} (defs|classify|langs)");
            2
        }
    }
}

fn text<'a>(node: Node, source: &'a [u8]) -> &'a str {
    node.utf8_text(source).unwrap_or("")
}

/// First line of the node, trimmed — the human signature.
fn signature(node: Node, source: &[u8]) -> String {
    text(node, source).lines().next().unwrap_or("").trim().to_string()
}

fn def_name(node: Node, source: &[u8]) -> Option<String> {
    if let Some(name) = node.child_by_field_name("name") {
        return Some(text(name, source).to_string());
    }
    // rust impl_item: use the type field; go type_declaration: first type_spec name.
    if let Some(type_node) = node.child_by_field_name("type") {
        return Some(text(type_node, source).to_string());
    }
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        if child.kind() == "type_spec" || child.kind() == "variable_declarator" {
            if let Some(name) = child.child_by_field_name("name") {
                return Some(text(name, source).to_string());
            }
        }
    }
    None
}

fn collect_defs(node: Node, source: &[u8], kinds: &[&str], out: &mut Vec<serde_json::Value>) {
    if kinds.contains(&node.kind()) {
        if let Some(name) = def_name(node, source) {
            out.push(serde_json::json!({
                "kind": node.kind(),
                "name": name,
                "line_start": node.start_position().row + 1,
                "line_end": node.end_position().row + 1,
                "signature": signature(node, source),
            }));
        }
    }
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        collect_defs(child, source, kinds, out);
    }
}

/// Every identifier equal to `symbol`, classified def/call/ref.
fn classify(node: Node, source: &[u8], symbol: &str, def_kinds: &[&str], out: &mut Vec<serde_json::Value>) {
    let kind = node.kind();
    let is_identifier = kind.contains("identifier") || kind == "field_identifier" || kind == "word";
    if is_identifier && text(node, source) == symbol {
        let classification = classify_site(node, def_kinds);
        let line = node.start_position().row + 1;
        let context = line_of(source, node.start_position().row);
        out.push(serde_json::json!({
            "line": line,
            "kind": classification,
            "context": context.trim_end(),
        }));
    }
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        classify(child, source, symbol, def_kinds, out);
    }
}

fn classify_site(node: Node, def_kinds: &[&str]) -> &'static str {
    if let Some(parent) = node.parent() {
        // The name of a definition node ⇒ def.
        if def_kinds.contains(&parent.kind()) {
            if let Some(name) = parent.child_by_field_name("name") {
                if name.id() == node.id() {
                    return "def";
                }
            }
        }
        // The function position of a call ⇒ call.
        let mut current = node;
        let mut ancestor = parent;
        loop {
            let kind = ancestor.kind();
            if kind == "call_expression" || kind == "call" || kind == "macro_invocation" || kind == "command" {
                let callee = ancestor
                    .child_by_field_name("function")
                    .or_else(|| ancestor.child_by_field_name("name"))
                    .or_else(|| ancestor.child_by_field_name("macro"));
                if let Some(callee) = callee {
                    if contains_node(callee, current) {
                        return "call";
                    }
                }
                break;
            }
            // Walk up through field/scoped expressions to find the call node.
            if !matches!(kind, "field_expression" | "scoped_identifier" | "attribute" | "member_expression" | "selector_expression") {
                break;
            }
            current = ancestor;
            match ancestor.parent() {
                Some(next) => ancestor = next,
                None => break,
            }
        }
    }
    "ref"
}

fn contains_node(haystack: Node, needle: Node) -> bool {
    haystack.id() == needle.id()
        || (haystack.start_byte() <= needle.start_byte() && haystack.end_byte() >= needle.end_byte())
}

fn line_of(source: &[u8], row: usize) -> String {
    String::from_utf8_lossy(source)
        .lines()
        .nth(row)
        .unwrap_or("")
        .to_string()
}
