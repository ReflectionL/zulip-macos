//! A small TeX math parser for the formulas Zulip sends.
//!
//! Zulip renders `$$…$$` and ```` ```math ```` with `KaTeX` and keeps the original
//! TeX in an `annotation` element. This module turns that TeX into a bounded
//! tree the app can lay out natively, plus a linear Unicode form for text that
//! flows inside a sentence. Unknown commands are shown as written; nothing here
//! can fail or recurse without limit.

/// Longest formula (in bytes) that is parsed; longer ones stay plain text.
pub const MAX_TEX_BYTES: usize = 4_096;
const MAX_DEPTH: usize = 24;
const MAX_NODES: usize = 3_000;
/// Widest and tallest matrix kept.
const MAX_MATRIX_CELLS: usize = 400;

/// How a symbol is spaced and stretched.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SymbolClass {
    /// Plain symbol with no extra space.
    Ordinary,
    /// Operator such as `+` with space on both sides.
    Binary,
    /// Relation such as `=` with wider space on both sides.
    Relation,
    /// Comma or semicolon, with space after.
    Punctuation,
    /// Large operator such as `∑` that may carry limits.
    Large,
    /// Opening bracket.
    Open,
    /// Closing bracket.
    Close,
}

/// A mark drawn over or under a group.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MathAccent {
    /// `\hat`
    Hat,
    /// `\bar`
    Bar,
    /// `\vec`
    Vector,
    /// `\dot`
    Dot,
    /// `\ddot`
    DoubleDot,
    /// `\tilde`
    Tilde,
    /// `\overline`
    Overline,
    /// `\underline`
    Underline,
}

/// How the columns of a matrix-like block line up.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MatrixAlignment {
    /// Every column centered (`matrix`, `pmatrix`, …).
    Centered,
    /// Every column left aligned (`cases`).
    Leading,
    /// Columns alternate right and left, for `aligned` equations.
    Equations,
}

/// One element of a parsed formula.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum MathNode {
    /// A variable, drawn in italics.
    Ident(String),
    /// A number such as `3.14`.
    Number(String),
    /// An upright symbol.
    Symbol {
        /// The glyph.
        text: String,
        /// Spacing class.
        class: SymbolClass,
    },
    /// Upright text from `\text` or `\mathrm`.
    Text(String),
    /// A named function such as `sin`, followed by a thin space.
    Function(String),
    /// Horizontal space in eighteenths of an em.
    Space(u32),
    /// Nodes grouped by braces.
    Group(Vec<MathNode>),
    /// A fraction; `rule` is false for `\binom`.
    Fraction {
        /// Top part.
        numerator: Vec<MathNode>,
        /// Bottom part.
        denominator: Vec<MathNode>,
        /// Whether the dividing line is drawn.
        rule: bool,
    },
    /// A root; `index` is empty for a square root.
    Root {
        /// Degree of the root.
        index: Vec<MathNode>,
        /// Radicand.
        body: Vec<MathNode>,
    },
    /// A base with a subscript and/or superscript.
    Script {
        /// The nodes the scripts attach to.
        base: Vec<MathNode>,
        /// Subscript.
        sub: Vec<MathNode>,
        /// Superscript.
        sup: Vec<MathNode>,
        /// Whether the scripts sit above and below the base.
        limits: bool,
    },
    /// Content between stretchy delimiters from `\left` and `\right`.
    Fenced {
        /// Opening delimiter; empty for none.
        open: String,
        /// Closing delimiter; empty for none.
        close: String,
        /// Enclosed content.
        body: Vec<MathNode>,
    },
    /// A group with a mark over or under it.
    Accent {
        /// The mark.
        accent: MathAccent,
        /// The marked content.
        body: Vec<MathNode>,
    },
    /// A matrix, `cases` or aligned block.
    Matrix {
        /// Number of columns.
        columns: usize,
        /// Cells in row-major order, `columns` per row.
        cells: Vec<Vec<MathNode>>,
        /// Opening delimiter; empty for none.
        open: String,
        /// Closing delimiter; empty for none.
        close: String,
        /// Column alignment.
        alignment: MatrixAlignment,
    },
}

/// Parses TeX math. Never fails: markup it does not know is kept as text.
#[must_use]
pub fn parse_tex(source: &str) -> Vec<MathNode> {
    if source.len() > MAX_TEX_BYTES {
        return vec![MathNode::Text(source.to_owned())];
    }
    let mut parser = Parser::new(source);
    let mut nodes = Vec::new();
    // A stray `}` or `\right` ends one sequence; keep reading the rest.
    while parser.peek().is_some() {
        let (more, _) = parser.sequence(0);
        nodes.extend(more);
    }
    nodes
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Stop {
    End,
    Brace,
    Right,
    EndEnv,
    Ampersand,
    RowBreak,
}

struct Parser {
    chars: Vec<char>,
    pos: usize,
    nodes: usize,
}

impl Parser {
    fn new(source: &str) -> Self {
        Self {
            chars: source.chars().collect(),
            pos: 0,
            nodes: 0,
        }
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn next(&mut self) -> Option<char> {
        let value = self.peek();
        if value.is_some() {
            self.pos += 1;
        }
        value
    }

    fn skip_space(&mut self) {
        while self.peek().is_some_and(char::is_whitespace) {
            self.pos += 1;
        }
    }

    fn exhausted(&self, depth: usize) -> bool {
        depth > MAX_DEPTH || self.nodes > MAX_NODES
    }

    fn abort(&mut self) {
        self.pos = self.chars.len();
    }

    /// The name after a backslash: a run of ASCII letters, or one other character.
    fn command_name(&mut self) -> String {
        match self.peek() {
            Some(c) if c.is_ascii_alphabetic() => {
                let mut name = String::new();
                while let Some(c) = self.peek().filter(char::is_ascii_alphabetic) {
                    name.push(c);
                    self.pos += 1;
                }
                name
            }
            Some(c) => {
                self.pos += 1;
                c.to_string()
            }
            None => String::new(),
        }
    }

    fn sequence(&mut self, depth: usize) -> (Vec<MathNode>, Stop) {
        let mut out: Vec<MathNode> = Vec::new();
        loop {
            self.skip_space();
            if self.exhausted(depth) {
                self.abort();
                return (finish(out), Stop::End);
            }
            let Some(c) = self.peek() else {
                return (finish(out), Stop::End);
            };
            match c {
                '}' => {
                    self.pos += 1;
                    return (finish(out), Stop::Brace);
                }
                '&' => {
                    self.pos += 1;
                    return (finish(out), Stop::Ampersand);
                }
                '\\' => {
                    let start = self.pos;
                    self.pos += 1;
                    if self.peek() == Some('\\') {
                        self.pos += 1;
                        self.skip_space();
                        if self.peek() == Some('[') {
                            // `\\[2pt]` row spacing.
                            while let Some(c) = self.next() {
                                if c == ']' {
                                    break;
                                }
                            }
                        }
                        return (finish(out), Stop::RowBreak);
                    }
                    match self.command_name().as_str() {
                        "right" => return (finish(out), Stop::Right),
                        "end" => {
                            self.raw_text_argument();
                            return (finish(out), Stop::EndEnv);
                        }
                        _ => self.pos = start,
                    }
                }
                _ => {}
            }
            if let Some(node) = self.atom_with_scripts(depth) {
                self.nodes += 1;
                out.push(node);
            }
        }
    }

    fn atom_with_scripts(&mut self, depth: usize) -> Option<MathNode> {
        let base = if matches!(self.peek(), Some('^' | '_')) {
            MathNode::Group(Vec::new())
        } else {
            self.atom(depth)?
        };
        self.skip_space();
        let mut limits_override = None;
        loop {
            let at = self.pos;
            if self.peek() == Some('\\') {
                self.pos += 1;
                match self.command_name().as_str() {
                    "limits" => limits_override = Some(true),
                    "nolimits" => limits_override = Some(false),
                    _ => {
                        self.pos = at;
                        break;
                    }
                }
                self.skip_space();
            } else {
                break;
            }
        }
        let mut sub: Vec<MathNode> = Vec::new();
        let mut sup: Vec<MathNode> = Vec::new();
        let mut has_scripts = false;
        loop {
            self.skip_space();
            match self.peek() {
                Some('^') => {
                    self.pos += 1;
                    has_scripts = true;
                    sup.extend(self.script_argument(depth));
                }
                Some('_') => {
                    self.pos += 1;
                    has_scripts = true;
                    sub.extend(self.script_argument(depth));
                }
                Some('\'') => {
                    self.pos += 1;
                    has_scripts = true;
                    sup.push(symbol("′", SymbolClass::Ordinary));
                }
                _ => break,
            }
            if self.exhausted(depth) {
                break;
            }
        }
        if !has_scripts {
            return Some(base);
        }
        let limits = limits_override.unwrap_or_else(|| takes_limits(&base));
        Some(MathNode::Script {
            base: vec![base],
            sub,
            sup,
            limits,
        })
    }

    fn script_argument(&mut self, depth: usize) -> Vec<MathNode> {
        self.skip_space();
        match self.peek() {
            Some('{') => {
                self.pos += 1;
                self.sequence(depth + 1).0
            }
            Some(c) if c.is_ascii_digit() => {
                self.pos += 1;
                vec![MathNode::Number(c.to_string())]
            }
            _ => self.atom(depth + 1).into_iter().collect(),
        }
    }

    /// One braced group, or a single atom.
    fn argument(&mut self, depth: usize) -> Vec<MathNode> {
        self.skip_space();
        if self.peek() == Some('{') {
            self.pos += 1;
            self.sequence(depth + 1).0
        } else {
            self.atom(depth + 1).into_iter().collect()
        }
    }

    /// The text of a braced group, with braces and commands removed.
    fn raw_text_argument(&mut self) -> String {
        self.skip_space();
        if self.peek() != Some('{') {
            return match self.next() {
                Some('\\') => format!("\\{}", self.command_name()),
                Some(c) => c.to_string(),
                None => String::new(),
            };
        }
        self.pos += 1;
        let mut level = 1_usize;
        let mut text = String::new();
        while let Some(c) = self.next() {
            match c {
                '{' => level += 1,
                '}' => {
                    level -= 1;
                    if level == 0 {
                        break;
                    }
                }
                '\\' => {
                    let name = self.command_name();
                    match name.as_str() {
                        " " | "," | ";" | ":" | "quad" | "qquad" => text.push(' '),
                        "&" | "%" | "$" | "#" | "_" => text.push_str(&name),
                        _ => {}
                    }
                }
                '~' => text.push('\u{a0}'),
                _ => text.push(c),
            }
        }
        text
    }

    fn optional_bracket(&mut self, depth: usize) -> Vec<MathNode> {
        self.skip_space();
        if self.peek() != Some('[') {
            return Vec::new();
        }
        self.pos += 1;
        let mut inner = String::new();
        let mut level = 0_usize;
        while let Some(c) = self.next() {
            match c {
                '{' => level += 1,
                '}' => level = level.saturating_sub(1),
                ']' if level == 0 => break,
                _ => {}
            }
            inner.push(c);
        }
        if depth > MAX_DEPTH {
            return Vec::new();
        }
        let mut parser = Parser::new(&inner);
        let mut nodes = Vec::new();
        while parser.peek().is_some() {
            nodes.extend(parser.sequence(depth + 1).0);
        }
        nodes
    }

    fn atom(&mut self, depth: usize) -> Option<MathNode> {
        if self.exhausted(depth) {
            self.abort();
            return None;
        }
        let c = self.next()?;
        Some(match c {
            '{' => MathNode::Group(self.sequence(depth + 1).0),
            '\\' => return self.command(depth),
            '0'..='9' => {
                let mut number = c.to_string();
                while let Some(next) = self.peek() {
                    let continues = next.is_ascii_digit()
                        || (next == '.'
                            && self
                                .chars
                                .get(self.pos + 1)
                                .is_some_and(char::is_ascii_digit));
                    if !continues {
                        break;
                    }
                    number.push(next);
                    self.pos += 1;
                }
                MathNode::Number(number)
            }
            '+' => symbol("+", SymbolClass::Binary),
            '-' => symbol("−", SymbolClass::Binary),
            '*' => symbol("∗", SymbolClass::Binary),
            '=' | '<' | '>' | ':' => symbol(&c.to_string(), SymbolClass::Relation),
            ',' | ';' => symbol(&c.to_string(), SymbolClass::Punctuation),
            '(' | '[' => symbol(&c.to_string(), SymbolClass::Open),
            ')' | ']' => symbol(&c.to_string(), SymbolClass::Close),
            '~' => MathNode::Space(6),
            '%' => {
                // A TeX comment runs to the end of the line.
                while self.next().is_some_and(|c| c != '\n') {}
                return None;
            }
            c if c.is_alphabetic() => MathNode::Ident(c.to_string()),
            c => symbol(&c.to_string(), SymbolClass::Ordinary),
        })
    }

    #[allow(clippy::too_many_lines)]
    fn command(&mut self, depth: usize) -> Option<MathNode> {
        let name = self.command_name();
        let name = name.as_str();
        Some(match name {
            "frac" | "dfrac" | "tfrac" | "cfrac" => {
                let numerator = self.argument(depth);
                let denominator = self.argument(depth);
                MathNode::Fraction {
                    numerator,
                    denominator,
                    rule: true,
                }
            }
            "binom" | "dbinom" | "tbinom" => {
                let numerator = self.argument(depth);
                let denominator = self.argument(depth);
                MathNode::Fenced {
                    open: "(".to_owned(),
                    close: ")".to_owned(),
                    body: vec![MathNode::Fraction {
                        numerator,
                        denominator,
                        rule: false,
                    }],
                }
            }
            "sqrt" => {
                let index = self.optional_bracket(depth);
                let body = self.argument(depth);
                MathNode::Root { index, body }
            }
            "text" | "textrm" | "textbf" | "textit" | "textsf" | "texttt" | "mbox" | "hbox"
            | "mathrm" | "mathsf" | "mathtt" | "mathnormal" => {
                MathNode::Text(self.raw_text_argument())
            }
            "operatorname" | "operatorname*" => MathNode::Function(self.raw_text_argument()),
            "mathbb" | "Bbb" => self.restyled(depth, blackboard),
            "mathcal" | "mathscr" | "cal" => self.restyled(depth, calligraphic),
            "mathfrak" | "frak" => self.restyled(depth, fraktur),
            "mathbf" | "boldsymbol" | "bm" | "pmb" | "bf" => self.restyled(depth, bold),
            "mathit" | "mit" | "it" => MathNode::Group(self.argument(depth)),
            "mathop" | "mathrel" | "mathbin" | "mathord" | "mathopen" | "mathclose"
            | "mathpunct" | "boxed" | "fbox" | "displaylines" => {
                MathNode::Group(self.argument(depth))
            }
            "hat" | "widehat" => self.accent(depth, MathAccent::Hat),
            "bar" => self.accent(depth, MathAccent::Bar),
            "vec" | "overrightarrow" | "overleftrightarrow" => {
                self.accent(depth, MathAccent::Vector)
            }
            "dot" => self.accent(depth, MathAccent::Dot),
            "ddot" => self.accent(depth, MathAccent::DoubleDot),
            "tilde" | "widetilde" => self.accent(depth, MathAccent::Tilde),
            "overline" => self.accent(depth, MathAccent::Overline),
            "underline" => self.accent(depth, MathAccent::Underline),
            "left" => {
                let open = self.delimiter();
                let (body, stop) = self.sequence(depth + 1);
                let close = if stop == Stop::Right {
                    self.delimiter()
                } else {
                    String::new()
                };
                MathNode::Fenced { open, close, body }
            }
            "middle" => symbol(&self.delimiter(), SymbolClass::Ordinary),
            "big" | "Big" | "bigg" | "Bigg" | "bigl" | "Bigl" | "biggl" | "Biggl" | "bigr"
            | "Bigr" | "biggr" | "Biggr" | "bigm" | "Bigm" => {
                let delimiter = self.delimiter();
                let class = match delimiter.as_str() {
                    "(" | "[" | "{" | "⟨" | "⌊" | "⌈" => SymbolClass::Open,
                    ")" | "]" | "}" | "⟩" | "⌋" | "⌉" => SymbolClass::Close,
                    _ => SymbolClass::Ordinary,
                };
                symbol(&delimiter, class)
            }
            "begin" => return Some(self.environment(depth)),
            "not" => {
                let target = self.atom(depth + 1)?;
                match target {
                    MathNode::Symbol { text, class } => {
                        let negated = negate(&text).map_or_else(
                            || format!("{text}\u{338}"),
                            std::borrow::ToOwned::to_owned,
                        );
                        MathNode::Symbol {
                            text: negated,
                            class,
                        }
                    }
                    other => other,
                }
            }
            "overset" | "stackrel" => {
                let top = self.argument(depth);
                let base = self.argument(depth);
                MathNode::Script {
                    base: vec![MathNode::Group(base)],
                    sub: Vec::new(),
                    sup: top,
                    limits: true,
                }
            }
            "underset" => {
                let bottom = self.argument(depth);
                let base = self.argument(depth);
                MathNode::Script {
                    base: vec![MathNode::Group(base)],
                    sub: bottom,
                    sup: Vec::new(),
                    limits: true,
                }
            }
            "xrightarrow" | "xleftarrow" | "xRightarrow" | "xLeftarrow" | "xleftrightarrow" => {
                let below = self.optional_bracket(depth);
                let above = self.argument(depth);
                let arrow = match name {
                    "xrightarrow" => "→",
                    "xleftarrow" => "←",
                    "xRightarrow" => "⇒",
                    "xLeftarrow" => "⇐",
                    _ => "↔",
                };
                MathNode::Script {
                    base: vec![symbol(arrow, SymbolClass::Relation)],
                    sub: below,
                    sup: above,
                    limits: true,
                }
            }
            "textcolor" | "colorbox" => {
                self.raw_text_argument();
                MathNode::Group(self.argument(depth))
            }
            "color" | "label" | "tag" | "hspace" | "vspace" | "hspace*" | "phantom"
            | "hphantom" | "vphantom" | "mathstrut" | "rule" | "ref" | "eqref" => {
                if name != "mathstrut" {
                    self.raw_text_argument();
                }
                return None;
            }
            "displaystyle" | "textstyle" | "scriptstyle" | "scriptscriptstyle" | "limits"
            | "nolimits" | "nonumber" | "notag" | "!" | "relax" | "protect" | "displaymath"
            | "allowbreak" | "strut" => return None,
            "," => MathNode::Space(3),
            ":" | ">" => MathNode::Space(4),
            ";" => MathNode::Space(5),
            " " => MathNode::Space(6),
            "quad" => MathNode::Space(18),
            "qquad" => MathNode::Space(36),
            "{" | "}" | "&" | "%" | "$" | "#" | "_" => symbol(name, SymbolClass::Ordinary),
            "|" => symbol("‖", SymbolClass::Ordinary),
            _ => {
                if let Some(node) = lookup_symbol(name) {
                    node
                } else {
                    MathNode::Text(format!("\\{name}"))
                }
            }
        })
    }

    fn accent(&mut self, depth: usize, accent: MathAccent) -> MathNode {
        MathNode::Accent {
            accent,
            body: self.argument(depth),
        }
    }

    fn restyled(&mut self, depth: usize, style: fn(char) -> char) -> MathNode {
        let body = self.argument(depth);
        restyle(MathNode::Group(body), style)
    }

    /// A delimiter after `\left`, `\right`, or `\big`: one character or a command.
    fn delimiter(&mut self) -> String {
        self.skip_space();
        match self.next() {
            None | Some('.') => String::new(),
            Some('\\') => {
                let name = self.command_name();
                match name.as_str() {
                    "{" | "lbrace" => "{",
                    "}" | "rbrace" => "}",
                    "|" | "Vert" | "lVert" | "rVert" | "Arrowvert" => "‖",
                    "vert" | "lvert" | "rvert" | "mvert" => "|",
                    "langle" | "lang" => "⟨",
                    "rangle" | "rang" => "⟩",
                    "lfloor" => "⌊",
                    "rfloor" => "⌋",
                    "lceil" => "⌈",
                    "rceil" => "⌉",
                    "backslash" => "\\",
                    "uparrow" => "↑",
                    "downarrow" => "↓",
                    _ => return String::new(),
                }
                .to_owned()
            }
            Some(c) => c.to_string(),
        }
    }

    fn environment(&mut self, depth: usize) -> MathNode {
        let name = self.raw_text_argument();
        if matches!(name.as_str(), "array" | "tabular" | "alignat" | "alignat*") {
            self.raw_text_argument();
        }
        let mut rows: Vec<Vec<Vec<MathNode>>> = Vec::new();
        let mut row: Vec<Vec<MathNode>> = Vec::new();
        loop {
            let (cell, stop) = self.sequence(depth + 1);
            row.push(cell);
            match stop {
                Stop::Ampersand => {}
                Stop::RowBreak => rows.push(std::mem::take(&mut row)),
                Stop::EndEnv | Stop::End | Stop::Brace | Stop::Right => {
                    rows.push(std::mem::take(&mut row));
                    break;
                }
            }
            if self.exhausted(depth) {
                self.abort();
                rows.push(std::mem::take(&mut row));
                break;
            }
        }
        // A trailing `\\` leaves one empty row.
        if rows.last().is_some_and(|row| row.iter().all(Vec::is_empty)) {
            rows.pop();
        }
        let columns = rows.iter().map(Vec::len).max().unwrap_or(1).max(1);
        let (open, close, alignment) = match name.trim_end_matches('*') {
            "pmatrix" => ("(", ")", MatrixAlignment::Centered),
            "bmatrix" => ("[", "]", MatrixAlignment::Centered),
            "Bmatrix" => ("{", "}", MatrixAlignment::Centered),
            "vmatrix" => ("|", "|", MatrixAlignment::Centered),
            "Vmatrix" => ("‖", "‖", MatrixAlignment::Centered),
            "cases" | "dcases" => ("{", "", MatrixAlignment::Leading),
            "rcases" => ("", "}", MatrixAlignment::Leading),
            "aligned" | "align" | "alignat" | "split" | "eqnarray" | "flalign" => {
                ("", "", MatrixAlignment::Equations)
            }
            _ => ("", "", MatrixAlignment::Centered),
        };
        let mut cells = Vec::new();
        for mut row in rows {
            row.resize_with(columns, Vec::new);
            cells.extend(row);
            if cells.len() > MAX_MATRIX_CELLS {
                break;
            }
        }
        cells.truncate(MAX_MATRIX_CELLS / columns * columns);
        self.nodes += cells.len();
        MathNode::Matrix {
            columns,
            cells,
            open: open.to_owned(),
            close: close.to_owned(),
            alignment,
        }
    }
}

fn symbol(text: &str, class: SymbolClass) -> MathNode {
    MathNode::Symbol {
        text: text.to_owned(),
        class,
    }
}

/// Turns binary operators that have nothing to their left into plain signs.
fn finish(mut nodes: Vec<MathNode>) -> Vec<MathNode> {
    for index in 0..nodes.len() {
        let unary = match index.checked_sub(1).map(|previous| &nodes[previous]) {
            None => true,
            Some(MathNode::Symbol { class, .. }) => matches!(
                class,
                SymbolClass::Binary
                    | SymbolClass::Relation
                    | SymbolClass::Open
                    | SymbolClass::Punctuation
                    | SymbolClass::Large
            ),
            Some(_) => false,
        };
        if unary
            && let MathNode::Symbol { class, .. } = &mut nodes[index]
            && *class == SymbolClass::Binary
        {
            *class = SymbolClass::Ordinary;
        }
    }
    nodes
}

const LIMIT_FUNCTIONS: &[&str] = &[
    "lim", "liminf", "limsup", "max", "min", "sup", "inf", "det", "gcd", "Pr",
];

fn takes_limits(base: &MathNode) -> bool {
    match base {
        MathNode::Symbol {
            text,
            class: SymbolClass::Large,
        } => !text.starts_with('∫') && !matches!(text.as_str(), "∬" | "∭" | "∮"),
        MathNode::Function(name) => LIMIT_FUNCTIONS.contains(&name.as_str()),
        _ => false,
    }
}

fn negate(text: &str) -> Option<&'static str> {
    Some(match text {
        "=" => "≠",
        "∈" => "∉",
        "∋" => "∌",
        "⊂" => "⊄",
        "⊃" => "⊅",
        "⊆" => "⊈",
        "⊇" => "⊉",
        "<" => "≮",
        ">" => "≯",
        "≤" => "≰",
        "≥" => "≱",
        "≡" => "≢",
        "∼" => "≁",
        "≈" => "≉",
        "≅" => "≇",
        "∣" => "∤",
        "∥" => "∦",
        _ => return None,
    })
}

const GREEK_LOWER: &[(&str, &str)] = &[
    ("alpha", "α"),
    ("beta", "β"),
    ("gamma", "γ"),
    ("delta", "δ"),
    ("epsilon", "ϵ"),
    ("varepsilon", "ε"),
    ("zeta", "ζ"),
    ("eta", "η"),
    ("theta", "θ"),
    ("vartheta", "ϑ"),
    ("iota", "ι"),
    ("kappa", "κ"),
    ("lambda", "λ"),
    ("mu", "μ"),
    ("nu", "ν"),
    ("xi", "ξ"),
    ("pi", "π"),
    ("rho", "ρ"),
    ("sigma", "σ"),
    ("tau", "τ"),
    ("upsilon", "υ"),
    ("phi", "ϕ"),
    ("chi", "χ"),
    ("psi", "ψ"),
];

const GREEK_OTHER: &[(&str, &str)] = &[
    ("omega", "ω"),
    ("varphi", "φ"),
    ("varrho", "ϱ"),
    ("varpi", "ϖ"),
    ("varsigma", "ς"),
    ("varkappa", "ϰ"),
    ("digamma", "ϝ"),
    ("imath", "ı"),
    ("jmath", "ȷ"),
];

const GREEK_UPPER: &[(&str, &str)] = &[
    ("Gamma", "Γ"),
    ("Delta", "Δ"),
    ("Theta", "Θ"),
    ("Lambda", "Λ"),
    ("Xi", "Ξ"),
    ("Pi", "Π"),
    ("Sigma", "Σ"),
    ("Upsilon", "Υ"),
    ("Phi", "Φ"),
    ("Psi", "Ψ"),
    ("Omega", "Ω"),
];

const BINARY: &[(&str, &str)] = &[
    ("pm", "±"),
    ("mp", "∓"),
    ("times", "×"),
    ("div", "÷"),
    ("cdot", "⋅"),
    ("ast", "∗"),
    ("star", "⋆"),
    ("circ", "∘"),
    ("bullet", "∙"),
    ("cup", "∪"),
    ("cap", "∩"),
    ("setminus", "∖"),
    ("land", "∧"),
    ("wedge", "∧"),
    ("lor", "∨"),
    ("vee", "∨"),
    ("oplus", "⊕"),
    ("ominus", "⊖"),
    ("otimes", "⊗"),
    ("odot", "⊙"),
    ("sqcup", "⊔"),
    ("sqcap", "⊓"),
    ("uplus", "⊎"),
    ("wr", "≀"),
];

const RELATIONS: &[(&str, &str)] = &[
    ("leq", "≤"),
    ("le", "≤"),
    ("geq", "≥"),
    ("ge", "≥"),
    ("neq", "≠"),
    ("ne", "≠"),
    ("approx", "≈"),
    ("sim", "∼"),
    ("simeq", "≃"),
    ("cong", "≅"),
    ("equiv", "≡"),
    ("propto", "∝"),
    ("ll", "≪"),
    ("gg", "≫"),
    ("subset", "⊂"),
    ("supset", "⊃"),
    ("subseteq", "⊆"),
    ("supseteq", "⊇"),
    ("in", "∈"),
    ("notin", "∉"),
    ("ni", "∋"),
    ("to", "→"),
    ("rightarrow", "→"),
    ("leftarrow", "←"),
    ("gets", "←"),
    ("leftrightarrow", "↔"),
    ("Rightarrow", "⇒"),
    ("Leftarrow", "⇐"),
    ("Leftrightarrow", "⇔"),
    ("iff", "⟺"),
    ("implies", "⟹"),
    ("impliedby", "⟸"),
    ("mapsto", "↦"),
    ("longrightarrow", "⟶"),
    ("longleftarrow", "⟵"),
    ("Longrightarrow", "⟹"),
    ("Longleftarrow", "⟸"),
    ("hookrightarrow", "↪"),
    ("uparrow", "↑"),
    ("downarrow", "↓"),
    ("mid", "∣"),
    ("parallel", "∥"),
    ("perp", "⊥"),
    ("vdash", "⊢"),
    ("models", "⊨"),
    ("asymp", "≍"),
    ("doteq", "≐"),
    ("prec", "≺"),
];

const ORDINARY: &[(&str, &str)] = &[
    ("infty", "∞"),
    ("partial", "∂"),
    ("nabla", "∇"),
    ("forall", "∀"),
    ("exists", "∃"),
    ("nexists", "∄"),
    ("neg", "¬"),
    ("lnot", "¬"),
    ("emptyset", "∅"),
    ("varnothing", "∅"),
    ("ldots", "…"),
    ("dots", "…"),
    ("cdots", "⋯"),
    ("vdots", "⋮"),
    ("ddots", "⋱"),
    ("prime", "′"),
    ("angle", "∠"),
    ("top", "⊤"),
    ("bot", "⊥"),
    ("hbar", "ℏ"),
    ("ell", "ℓ"),
    ("Re", "ℜ"),
    ("Im", "ℑ"),
    ("aleph", "ℵ"),
    ("wp", "℘"),
    ("square", "□"),
    ("triangle", "△"),
    ("degree", "°"),
    ("dagger", "†"),
    ("sharp", "♯"),
    ("flat", "♭"),
    ("natural", "♮"),
    ("checkmark", "✓"),
    ("langle", "⟨"),
    ("rangle", "⟩"),
    ("lfloor", "⌊"),
    ("rfloor", "⌋"),
    ("lceil", "⌈"),
    ("rceil", "⌉"),
    ("backslash", "\\"),
];

const LARGE: &[(&str, &str)] = &[
    ("sum", "∑"),
    ("prod", "∏"),
    ("coprod", "∐"),
    ("int", "∫"),
    ("iint", "∬"),
    ("iiint", "∭"),
    ("oint", "∮"),
    ("bigcup", "⋃"),
    ("bigcap", "⋂"),
    ("bigoplus", "⨁"),
    ("bigotimes", "⨂"),
    ("bigvee", "⋁"),
    ("bigwedge", "⋀"),
    ("biguplus", "⨄"),
];

const FUNCTIONS: &[&str] = &[
    "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
    "coth", "log", "ln", "lg", "exp", "det", "dim", "ker", "deg", "gcd", "hom", "arg", "Pr", "inf",
    "sup", "lim", "liminf", "limsup", "max", "min", "mod",
];

fn find(table: &[(&'static str, &'static str)], name: &str) -> Option<&'static str> {
    table
        .iter()
        .find(|(key, _)| *key == name)
        .map(|(_, value)| *value)
}

fn lookup_symbol(name: &str) -> Option<MathNode> {
    if let Some(glyph) = find(GREEK_LOWER, name).or_else(|| find(GREEK_OTHER, name)) {
        return Some(MathNode::Ident(glyph.to_owned()));
    }
    if let Some(glyph) = find(GREEK_UPPER, name) {
        return Some(symbol(glyph, SymbolClass::Ordinary));
    }
    if let Some(glyph) = find(BINARY, name) {
        return Some(symbol(glyph, SymbolClass::Binary));
    }
    if let Some(glyph) = find(RELATIONS, name) {
        return Some(symbol(glyph, SymbolClass::Relation));
    }
    if let Some(glyph) = find(LARGE, name) {
        return Some(symbol(glyph, SymbolClass::Large));
    }
    if let Some(glyph) = find(ORDINARY, name) {
        let class = match glyph {
            "⟨" | "⌊" | "⌈" => SymbolClass::Open,
            "⟩" | "⌋" | "⌉" => SymbolClass::Close,
            _ => SymbolClass::Ordinary,
        };
        return Some(symbol(glyph, class));
    }
    FUNCTIONS
        .contains(&name)
        .then(|| MathNode::Function(name.to_owned()))
}

fn shifted(c: char, first: char, base: u32) -> char {
    char::from_u32(base + (c as u32 - first as u32)).unwrap_or(c)
}

fn blackboard(c: char) -> char {
    match c {
        'C' => 'ℂ',
        'H' => 'ℍ',
        'N' => 'ℕ',
        'P' => 'ℙ',
        'Q' => 'ℚ',
        'R' => 'ℝ',
        'Z' => 'ℤ',
        'A'..='Z' => shifted(c, 'A', 0x1D538),
        'a'..='z' => shifted(c, 'a', 0x1D552),
        '0'..='9' => shifted(c, '0', 0x1D7D8),
        _ => c,
    }
}

fn calligraphic(c: char) -> char {
    match c {
        'B' => 'ℬ',
        'E' => 'ℰ',
        'F' => 'ℱ',
        'H' => 'ℋ',
        'I' => 'ℐ',
        'L' => 'ℒ',
        'M' => 'ℳ',
        'R' => 'ℛ',
        'e' => 'ℯ',
        'g' => 'ℊ',
        'o' => 'ℴ',
        'A'..='Z' => shifted(c, 'A', 0x1D49C),
        'a'..='z' => shifted(c, 'a', 0x1D4B6),
        _ => c,
    }
}

fn fraktur(c: char) -> char {
    match c {
        'C' => 'ℭ',
        'H' => 'ℌ',
        'I' => 'ℑ',
        'R' => 'ℜ',
        'Z' => 'ℨ',
        'A'..='Z' => shifted(c, 'A', 0x1D504),
        'a'..='z' => shifted(c, 'a', 0x1D51E),
        _ => c,
    }
}

fn bold(c: char) -> char {
    match c {
        'A'..='Z' => shifted(c, 'A', 0x1D400),
        'a'..='z' => shifted(c, 'a', 0x1D41A),
        '0'..='9' => shifted(c, '0', 0x1D7CE),
        _ => c,
    }
}

/// Re-draws letters and digits in a different alphabet (`\mathbb`, `\mathbf`, …).
fn restyle(node: MathNode, style: fn(char) -> char) -> MathNode {
    let many = |nodes: Vec<MathNode>| -> Vec<MathNode> {
        nodes.into_iter().map(|node| restyle(node, style)).collect()
    };
    match node {
        MathNode::Ident(text) | MathNode::Number(text) => {
            MathNode::Text(text.chars().map(style).collect())
        }
        MathNode::Group(nodes) => MathNode::Group(many(nodes)),
        MathNode::Script {
            base,
            sub,
            sup,
            limits,
        } => MathNode::Script {
            base: many(base),
            sub: many(sub),
            sup: many(sup),
            limits,
        },
        MathNode::Accent { accent, body } => MathNode::Accent {
            accent,
            body: many(body),
        },
        other => other,
    }
}

// ---- Linear Unicode form ----

/// The formula as one line of Unicode text, for use inside a sentence.
#[must_use]
pub fn to_linear(nodes: &[MathNode]) -> String {
    linear(nodes, true).trim().to_owned()
}

fn italic_letter(c: char) -> char {
    match c {
        'h' => 'ℎ',
        'A'..='Z' => shifted(c, 'A', 0x1D434),
        'a'..='z' => shifted(c, 'a', 0x1D44E),
        _ => c,
    }
}

fn superscript(c: char) -> Option<char> {
    Some(match c {
        '0' => '⁰',
        '1' => '¹',
        '2' => '²',
        '3' => '³',
        '4'..='9' => shifted(c, '4', 0x2074),
        '+' => '⁺',
        '-' | '−' => '⁻',
        '=' => '⁼',
        '(' => '⁽',
        ')' => '⁾',
        '′' => '′',
        'a' => 'ᵃ',
        'b' => 'ᵇ',
        'c' => 'ᶜ',
        'd' => 'ᵈ',
        'e' => 'ᵉ',
        'f' => 'ᶠ',
        'g' => 'ᵍ',
        'h' => 'ʰ',
        'i' => 'ⁱ',
        'j' => 'ʲ',
        'k' => 'ᵏ',
        'l' => 'ˡ',
        'm' => 'ᵐ',
        'n' => 'ⁿ',
        'o' => 'ᵒ',
        'p' => 'ᵖ',
        'r' => 'ʳ',
        's' => 'ˢ',
        't' => 'ᵗ',
        'u' => 'ᵘ',
        'v' => 'ᵛ',
        'w' => 'ʷ',
        'x' => 'ˣ',
        'y' => 'ʸ',
        'z' => 'ᶻ',
        'T' => 'ᵀ',
        '∗' => '*',
        _ => return None,
    })
}

fn subscript(c: char) -> Option<char> {
    Some(match c {
        '0'..='9' => shifted(c, '0', 0x2080),
        '+' => '₊',
        '-' | '−' => '₋',
        '=' => '₌',
        '(' => '₍',
        ')' => '₎',
        'a' => 'ₐ',
        'e' => 'ₑ',
        'h' => 'ₕ',
        'i' => 'ᵢ',
        'j' => 'ⱼ',
        'k' => 'ₖ',
        'l' => 'ₗ',
        'm' => 'ₘ',
        'n' => 'ₙ',
        'o' => 'ₒ',
        'p' => 'ₚ',
        'r' => 'ᵣ',
        's' => 'ₛ',
        't' => 'ₜ',
        'u' => 'ᵤ',
        'v' => 'ᵥ',
        'x' => 'ₓ',
        _ => return None,
    })
}

fn script_text(nodes: &[MathNode], convert: fn(char) -> Option<char>, marker: char) -> String {
    let plain: String = linear(nodes, false)
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect();
    if plain.is_empty() {
        return String::new();
    }
    if let Some(converted) = plain.chars().map(convert).collect::<Option<String>>() {
        return converted;
    }
    let shown = linear(nodes, true);
    let shown = shown.trim();
    if shown.chars().count() == 1 {
        format!("{marker}{shown}")
    } else {
        format!("{marker}({shown})")
    }
}

fn is_simple(text: &str) -> bool {
    !text.is_empty() && text.chars().all(char::is_alphanumeric)
}

fn wrap_if_complex(text: &str) -> String {
    if is_simple(text) {
        text.to_owned()
    } else {
        format!("({text})")
    }
}

fn combining(accent: MathAccent) -> char {
    match accent {
        MathAccent::Hat => '\u{302}',
        MathAccent::Bar => '\u{304}',
        MathAccent::Vector => '\u{20D7}',
        MathAccent::Dot => '\u{307}',
        MathAccent::DoubleDot => '\u{308}',
        MathAccent::Tilde => '\u{303}',
        MathAccent::Overline => '\u{305}',
        MathAccent::Underline => '\u{332}',
    }
}

fn gives_space_after(node: &MathNode) -> bool {
    match node {
        MathNode::Function(_)
        | MathNode::Symbol {
            class: SymbolClass::Large,
            ..
        } => true,
        MathNode::Script { base, .. } => base.iter().any(gives_space_after),
        _ => false,
    }
}

fn starts_with_space_breaker(node: &MathNode) -> bool {
    matches!(
        node,
        MathNode::Symbol {
            class: SymbolClass::Binary
                | SymbolClass::Relation
                | SymbolClass::Punctuation
                | SymbolClass::Close,
            ..
        } | MathNode::Space(_)
    )
}

fn linear(nodes: &[MathNode], italic: bool) -> String {
    let mut out = String::new();
    for (index, node) in nodes.iter().enumerate() {
        out.push_str(&linear_node(node, italic));
        if gives_space_after(node)
            && nodes
                .get(index + 1)
                .is_some_and(|next| !starts_with_space_breaker(next))
        {
            out.push('\u{2009}');
        }
    }
    out
}

#[allow(clippy::too_many_lines)]
fn linear_node(node: &MathNode, italic: bool) -> String {
    match node {
        MathNode::Ident(text) => {
            let mut chars = text.chars();
            match (chars.next(), chars.next()) {
                (Some(c), None) if italic && c.is_ascii_alphabetic() => {
                    italic_letter(c).to_string()
                }
                _ => text.clone(),
            }
        }
        MathNode::Number(text) | MathNode::Text(text) | MathNode::Function(text) => text.clone(),
        MathNode::Symbol { text, class } => match class {
            SymbolClass::Binary | SymbolClass::Relation => format!(" {text} "),
            SymbolClass::Punctuation => format!("{text} "),
            _ => text.clone(),
        },
        MathNode::Space(width) => match *width {
            0..=3 => "\u{2009}".to_owned(),
            4..=8 => " ".to_owned(),
            9..=18 => "  ".to_owned(),
            _ => "    ".to_owned(),
        },
        MathNode::Group(nodes) => linear(nodes, italic),
        MathNode::Fraction {
            numerator,
            denominator,
            rule,
        } => {
            let top = linear(numerator, italic);
            let bottom = linear(denominator, italic);
            let (top, bottom) = (top.trim(), bottom.trim());
            if *rule {
                format!("{}/{}", wrap_if_complex(top), wrap_if_complex(bottom))
            } else {
                format!("({top} choose {bottom})")
            }
        }
        MathNode::Root { index, body } => {
            let inner = linear(body, italic);
            let inner = wrap_if_complex(inner.trim());
            let degree = linear(index, false);
            match degree.trim() {
                "" | "2" => format!("√{inner}"),
                "3" => format!("∛{inner}"),
                "4" => format!("∜{inner}"),
                other => format!(
                    "{}√{inner}",
                    script_text(&[MathNode::Text(other.to_owned())], superscript, '^')
                ),
            }
        }
        MathNode::Script { base, sub, sup, .. } => {
            let mut text = linear(base, italic);
            text.push_str(&script_text(sub, subscript, '_'));
            text.push_str(&script_text(sup, superscript, '^'));
            text
        }
        MathNode::Fenced { open, close, body } => {
            format!("{open}{}{close}", linear(body, italic).trim())
        }
        MathNode::Accent { accent, body } => {
            let inner = linear(body, italic);
            let mark = combining(*accent);
            if matches!(accent, MathAccent::Overline | MathAccent::Underline) {
                inner
                    .chars()
                    .flat_map(|c| {
                        if c.is_whitespace() {
                            vec![c]
                        } else {
                            vec![c, mark]
                        }
                    })
                    .collect()
            } else {
                let mut text = inner;
                text.push(mark);
                text
            }
        }
        MathNode::Matrix {
            columns,
            cells,
            open,
            close,
            ..
        } => {
            let rows: Vec<String> = cells
                .chunks((*columns).max(1))
                .map(|row| {
                    row.iter()
                        .map(|cell| linear(cell, italic).trim().to_owned())
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .collect();
            format!("{open}{}{close}", rows.join("; "))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn linear_of(tex: &str) -> String {
        to_linear(&parse_tex(tex))
    }

    #[test]
    fn variables_numbers_and_relations_read_naturally() {
        assert_eq!(linear_of("x^2 + y^2 = 1"), "𝑥² + 𝑦² = 1");
        assert_eq!(linear_of("a_{ij}"), "𝑎ᵢⱼ");
        assert_eq!(linear_of("3.14"), "3.14");
    }

    #[test]
    fn fractions_roots_and_functions() {
        assert_eq!(linear_of(r"\frac{a}{b}"), "𝑎/𝑏");
        assert_eq!(linear_of(r"\frac{a+b}{2}"), "(𝑎 + 𝑏)/2");
        assert_eq!(linear_of(r"\sqrt{x+1}"), "√(𝑥 + 1)");
        assert_eq!(linear_of(r"\sqrt[3]{x}"), "∛𝑥");
        assert_eq!(linear_of(r"\sin^2 x"), "sin²\u{2009}𝑥");
    }

    #[test]
    fn greek_letters_and_operators() {
        assert_eq!(linear_of(r"\alpha \leq \beta"), "α ≤ β");
        assert_eq!(linear_of(r"\sum_{i=1}^{n} i"), "∑ᵢ₌₁ⁿ\u{2009}𝑖");
        assert_eq!(
            linear_of(r"\int_0^\infty e^{-x}\,dx"),
            "∫₀^∞\u{2009}𝑒⁻ˣ\u{2009}𝑑𝑥"
        );
    }

    #[test]
    fn alphabets_and_unary_minus() {
        assert_eq!(linear_of(r"\mathbb{R}^n"), "ℝⁿ");
        assert_eq!(linear_of(r"\mathcal{L}"), "ℒ");
        assert_eq!(linear_of("-x"), "−𝑥");
        assert_eq!(linear_of("a-b"), "𝑎 − 𝑏");
    }

    #[test]
    fn fences_matrices_and_accents() {
        assert_eq!(linear_of(r"\left( \frac{a}{b} \right)"), "(𝑎/𝑏)");
        assert_eq!(
            linear_of(r"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"),
            "(𝑎, 𝑏; 𝑐, 𝑑)"
        );
        assert_eq!(linear_of(r"\hat{x}"), "𝑥\u{302}");
        assert_eq!(linear_of(r"\text{if } x"), "if 𝑥");
    }

    #[test]
    fn matrices_keep_their_shape() {
        let nodes = parse_tex(r"\begin{cases} 1 & x > 0 \\ 0 & \text{otherwise} \end{cases}");
        let [
            MathNode::Matrix {
                columns,
                cells,
                open,
                close,
                alignment,
            },
        ] = nodes.as_slice()
        else {
            panic!("expected one matrix, got {nodes:?}");
        };
        assert_eq!((*columns, cells.len()), (2, 4));
        assert_eq!((open.as_str(), close.as_str()), ("{", ""));
        assert_eq!(*alignment, MatrixAlignment::Leading);
    }

    #[test]
    fn big_operators_take_limits_but_integrals_do_not() {
        let sum = parse_tex(r"\sum_{i}^{n}");
        assert!(matches!(&sum[..], [MathNode::Script { limits: true, .. }]));
        let integral = parse_tex(r"\int_0^1");
        assert!(matches!(
            &integral[..],
            [MathNode::Script { limits: false, .. }]
        ));
        let limit = parse_tex(r"\lim_{x \to 0}");
        assert!(matches!(
            &limit[..],
            [MathNode::Script { limits: true, .. }]
        ));
    }

    #[test]
    fn unknown_commands_are_kept_as_written() {
        assert_eq!(linear_of(r"\foo{x}"), "\\foo𝑥");
    }

    #[test]
    fn malformed_input_never_panics() {
        for tex in [
            "{{{{",
            "}}}}",
            r"\left(",
            r"\right)",
            r"\begin{pmatrix} a &",
            r"\begin{",
            "^",
            "_^_^",
            r"\frac{",
            r"\sqrt[",
            r"\",
            "x^",
            r"\end{matrix}",
            "a & b \\\\ c",
        ] {
            let _ = to_linear(&parse_tex(tex));
        }
        let deep = "{".repeat(10_000);
        let _ = parse_tex(&deep);
        let long = "x+".repeat(5_000);
        assert!(matches!(&parse_tex(&long)[..], [MathNode::Text(_)]));
    }
}
