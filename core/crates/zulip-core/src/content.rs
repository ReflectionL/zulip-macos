//! Bounded normalization of untrusted Zulip-rendered HTML.

use ego_tree::NodeRef;
use scraper::{CaseSensitivity, Html, Node, node::Element};
use url::Url;

const MAX_INPUT_BYTES: usize = 1_048_576;
const MAX_OUTPUT_TEXT_BYTES: usize = 262_144;
const MAX_VISITED_NODES: usize = 8_192;
const MAX_BLOCKS: usize = 256;
const MAX_DEPTH: usize = 32;
const MAX_URL_BYTES: usize = 4_096;
const MAX_EMOJI_NAME_BYTES: usize = 128;
const MAX_IMAGE_DIMENSION: u32 = 4_096;

/// Native inline content safe to cross the application bridge.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum InlineContent {
    /// Plain display text.
    Text(String),
    /// A label and sanitized URL.
    Link {
        /// Visible label.
        label: String,
        /// `http`, `https`, `mailto`, or account-relative destination.
        url: String,
    },
    /// A Zulip user mention.
    Mention {
        /// Mention display name without Zulip markup.
        display_name: String,
        /// Zulip user identifier.
        user_id: i64,
    },
    /// A rendered emoji or custom emoji placeholder.
    Emoji {
        /// Stable Zulip emoji name.
        name: String,
        /// Readable fallback value, normally `:name:`.
        value: String,
    },
}

/// Native block content produced from untrusted Zulip HTML.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ContentBlock {
    /// One paragraph or heading.
    Paragraph(Vec<InlineContent>),
    /// A nested quotation.
    Quote(Vec<ContentBlock>),
    /// An ordered or unordered list.
    List {
        /// Native blocks in each list item.
        items: Vec<Vec<ContentBlock>>,
        /// Whether numeric markers should be shown.
        ordered: bool,
    },
    /// A fenced or preformatted code block.
    Code {
        /// Optional language hint.
        language: Option<String>,
        /// Exact readable code text.
        value: String,
    },
    /// An image reference that Swift must not fetch without account-aware media handling.
    Image {
        /// Sanitized absolute or account-relative source.
        url: String,
        /// Readable alternative text.
        alt: String,
        /// Bounded server width hint.
        width: Option<u32>,
        /// Bounded server height hint.
        height: Option<u32>,
    },
    /// Readable fallback for unsupported or unsafe block markup.
    Unsupported {
        /// Sanitized human-readable summary.
        summary: String,
    },
}

/// Parses rendered Zulip HTML into bounded native blocks.
///
/// Browser-grade fragment parsing recovers malformed markup. Executable tags
/// and unsafe URL schemes are never represented in the result. If an input or
/// output bound is exceeded, a single readable unsupported block is returned.
#[must_use]
pub fn parse_zulip_html(html: &str) -> Vec<ContentBlock> {
    if html.len() > MAX_INPUT_BYTES {
        return vec![limit_block()];
    }
    let document = Html::parse_fragment(html);
    let mut parser = ContentParser::default();
    let mut blocks = Vec::new();
    for child in document.tree.root().children() {
        blocks.extend(parser.parse_block_node(child, 0));
        if parser.exhausted() {
            return vec![limit_block()];
        }
    }
    blocks.retain(|block| !block_is_empty(block));
    if blocks.is_empty() {
        vec![ContentBlock::Paragraph(vec![InlineContent::Text(
            readable_text_fallback(html),
        )])]
    } else {
        blocks
    }
}

#[derive(Default)]
struct ContentParser {
    visited_nodes: usize,
    output_text_bytes: usize,
    blocks: usize,
    limit_exceeded: bool,
}

impl ContentParser {
    fn exhausted(&self) -> bool {
        self.limit_exceeded
            || self.visited_nodes > MAX_VISITED_NODES
            || self.output_text_bytes > MAX_OUTPUT_TEXT_BYTES
            || self.blocks > MAX_BLOCKS
    }

    fn visit(&mut self, depth: usize) -> bool {
        self.visited_nodes = self.visited_nodes.saturating_add(1);
        if depth > MAX_DEPTH || self.exhausted() {
            self.limit_exceeded = true;
            false
        } else {
            true
        }
    }

    fn record_text(&mut self, value: &str) {
        self.output_text_bytes = self.output_text_bytes.saturating_add(value.len());
        if self.output_text_bytes > MAX_OUTPUT_TEXT_BYTES {
            self.limit_exceeded = true;
        }
    }

    fn block(&mut self, block: ContentBlock) -> Vec<ContentBlock> {
        self.blocks = self.blocks.saturating_add(1);
        if self.blocks > MAX_BLOCKS {
            self.limit_exceeded = true;
            Vec::new()
        } else {
            vec![block]
        }
    }

    #[allow(clippy::too_many_lines)]
    fn parse_block_node(&mut self, node: NodeRef<'_, Node>, depth: usize) -> Vec<ContentBlock> {
        if !self.visit(depth) {
            return Vec::new();
        }
        match node.value() {
            Node::Text(text) => {
                let value = text.to_string();
                if value.trim().is_empty() {
                    Vec::new()
                } else {
                    self.record_text(&value);
                    self.block(ContentBlock::Paragraph(vec![InlineContent::Text(value)]))
                }
            }
            Node::Element(element) => match element.name() {
                "html" | "body" => self.parse_block_children(node, depth + 1),
                "head" => Vec::new(),
                "script" | "style" | "iframe" | "object" | "embed" | "template" | "svg"
                | "math" => self.block(unsafe_block()),
                "p" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                    let inline = self.parse_inline_children(node, depth + 1);
                    self.block(ContentBlock::Paragraph(inline))
                }
                "blockquote" => {
                    let nested = self.parse_block_children(node, depth + 1);
                    self.block(ContentBlock::Quote(nested))
                }
                "ul" | "ol" => self.parse_list(node, element.name() == "ol", depth + 1),
                "pre" => self.parse_code(node, element, depth + 1),
                "img" if !is_emoji(element) => self.parse_image(element),
                "div" | "section" | "article" => {
                    if has_class(element, "codehilite") {
                        self.parse_code(node, element, depth + 1)
                    } else if has_class(element, "message_inline_image") {
                        self.parse_inline_image(node)
                    } else {
                        self.parse_block_children(node, depth + 1)
                    }
                }
                "table" | "audio" | "video" | "details" => {
                    let readable = self.descendant_text(node, depth + 1);
                    let summary = if readable.trim().is_empty() {
                        "Unsupported content".to_owned()
                    } else {
                        format!("Unsupported content: {}", readable.trim())
                    };
                    self.record_text(&summary);
                    self.block(ContentBlock::Unsupported { summary })
                }
                "hr" => {
                    self.record_text("—");
                    self.block(ContentBlock::Paragraph(vec![InlineContent::Text(
                        "—".to_owned(),
                    )]))
                }
                _ => {
                    let inline = self.parse_inline_node(node, depth + 1);
                    if inline.is_empty() {
                        self.parse_block_children(node, depth + 1)
                    } else {
                        self.block(ContentBlock::Paragraph(inline))
                    }
                }
            },
            Node::Document | Node::Fragment => self.parse_block_children(node, depth + 1),
            Node::Doctype(_) | Node::Comment(_) | Node::ProcessingInstruction(_) => Vec::new(),
        }
    }

    fn parse_block_children(&mut self, node: NodeRef<'_, Node>, depth: usize) -> Vec<ContentBlock> {
        let mut blocks = Vec::new();
        for child in node.children() {
            blocks.extend(self.parse_block_node(child, depth));
            if self.exhausted() {
                break;
            }
        }
        blocks
    }

    fn parse_list(
        &mut self,
        node: NodeRef<'_, Node>,
        ordered: bool,
        depth: usize,
    ) -> Vec<ContentBlock> {
        let mut items = Vec::new();
        for child in node.children() {
            let Some(element) = child.value().as_element() else {
                continue;
            };
            if element.name() == "li" {
                let blocks = self.parse_block_children(child, depth);
                if blocks.is_empty() {
                    let inline = self.parse_inline_children(child, depth);
                    if !inline.is_empty() {
                        items.push(vec![ContentBlock::Paragraph(inline)]);
                    }
                } else {
                    items.push(blocks);
                }
            }
        }
        self.block(ContentBlock::List { items, ordered })
    }

    fn parse_code(
        &mut self,
        node: NodeRef<'_, Node>,
        element: &Element,
        depth: usize,
    ) -> Vec<ContentBlock> {
        let value = self.descendant_text(node, depth);
        let language = language_hint(node, element);
        self.record_text(&value);
        self.block(ContentBlock::Code { language, value })
    }

    fn parse_image(&mut self, element: &Element) -> Vec<ContentBlock> {
        let Some(url) = element.attr("src").and_then(safe_url) else {
            return self.block(ContentBlock::Unsupported {
                summary: "Unsafe image was omitted".to_owned(),
            });
        };
        let alt = element.attr("alt").unwrap_or("Image").trim().to_owned();
        let (width, height) = image_dimensions(element);
        self.record_text(&alt);
        self.block(ContentBlock::Image {
            url,
            alt,
            width,
            height,
        })
    }

    fn parse_inline_image(&mut self, node: NodeRef<'_, Node>) -> Vec<ContentBlock> {
        let image = node.descendants().find_map(|descendant| {
            descendant
                .value()
                .as_element()
                .filter(|element| element.name() == "img" && !is_emoji(element))
        });
        let Some(element) = image else {
            return self.block(ContentBlock::Unsupported {
                summary: "Unsupported image preview".to_owned(),
            });
        };
        self.parse_image(element)
    }

    fn parse_inline_children(
        &mut self,
        node: NodeRef<'_, Node>,
        depth: usize,
    ) -> Vec<InlineContent> {
        let mut inline = Vec::new();
        for child in node.children() {
            inline.extend(self.parse_inline_node(child, depth));
            if self.exhausted() {
                break;
            }
        }
        coalesce_text(inline)
    }

    fn parse_inline_node(&mut self, node: NodeRef<'_, Node>, depth: usize) -> Vec<InlineContent> {
        if !self.visit(depth) {
            return Vec::new();
        }
        match node.value() {
            Node::Text(text) => {
                let value = text.to_string();
                self.record_text(&value);
                vec![InlineContent::Text(value)]
            }
            Node::Element(element) => match element.name() {
                "script" | "style" | "iframe" | "object" | "embed" | "template" | "svg"
                | "math" => Vec::new(),
                "br" => {
                    self.record_text("\n");
                    vec![InlineContent::Text("\n".to_owned())]
                }
                "a" => {
                    let label = self.descendant_text(node, depth + 1);
                    self.record_text(&label);
                    if let Some(url) = element.attr("href").and_then(safe_url) {
                        vec![InlineContent::Link { label, url }]
                    } else {
                        vec![InlineContent::Text(label)]
                    }
                }
                "span" if is_emoji(element) => {
                    let value = self.descendant_text(node, depth + 1);
                    let value = if value.is_empty() {
                        element.attr("alt").unwrap_or(":emoji:").to_owned()
                    } else {
                        value
                    };
                    let name = emoji_name(element, &value);
                    self.record_text(&value);
                    vec![InlineContent::Emoji { name, value }]
                }
                "span" if has_class(element, "user-mention") => {
                    let display_name = self
                        .descendant_text(node, depth + 1)
                        .trim()
                        .trim_start_matches('@')
                        .trim_matches('*')
                        .to_owned();
                    let user_id = element
                        .attr("data-user-id")
                        .and_then(|value| value.parse::<i64>().ok());
                    self.record_text(&display_name);
                    if let Some(user_id) = user_id.filter(|value| *value > 0)
                        && !display_name.is_empty()
                    {
                        vec![InlineContent::Mention {
                            display_name,
                            user_id,
                        }]
                    } else {
                        vec![InlineContent::Text(display_name)]
                    }
                }
                "img" if is_emoji(element) => {
                    let value = element.attr("alt").unwrap_or(":emoji:").to_owned();
                    let name = emoji_name(element, &value);
                    self.record_text(&value);
                    vec![InlineContent::Emoji { name, value }]
                }
                "img" => {
                    let alt = element.attr("alt").unwrap_or("Image").to_owned();
                    self.record_text(&alt);
                    vec![InlineContent::Text(alt)]
                }
                _ => self.parse_inline_children(node, depth + 1),
            },
            Node::Document | Node::Fragment => self.parse_inline_children(node, depth + 1),
            Node::Doctype(_) | Node::Comment(_) | Node::ProcessingInstruction(_) => Vec::new(),
        }
    }

    fn descendant_text(&mut self, node: NodeRef<'_, Node>, depth: usize) -> String {
        if depth > MAX_DEPTH {
            self.limit_exceeded = true;
            return String::new();
        }
        let mut text = String::new();
        for descendant in node.descendants() {
            self.visited_nodes = self.visited_nodes.saturating_add(1);
            if self.exhausted() {
                self.limit_exceeded = true;
                break;
            }
            if let Node::Text(value) = descendant.value() {
                if descendant.ancestors().any(|ancestor| {
                    ancestor
                        .value()
                        .as_element()
                        .is_some_and(|element| is_executable_element(element.name()))
                }) {
                    continue;
                }
                text.push_str(value);
            }
        }
        text
    }
}

fn safe_url(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty()
        || value.len() > MAX_URL_BYTES
        || value.contains('\\')
        || value.chars().any(char::is_control)
    {
        return None;
    }
    if (value.starts_with('/') && !value.starts_with("//")) || value.starts_with('#') {
        return Some(value.to_owned());
    }
    let parsed = Url::parse(value).ok()?;
    matches!(parsed.scheme(), "https" | "http" | "mailto").then(|| value.to_owned())
}

fn image_dimension(value: Option<&str>) -> Option<u32> {
    value?
        .parse::<u32>()
        .ok()
        .filter(|value| *value > 0 && *value <= MAX_IMAGE_DIMENSION)
}

fn image_dimensions(element: &Element) -> (Option<u32>, Option<u32>) {
    let width = image_dimension(element.attr("width"));
    let height = image_dimension(element.attr("height"));
    if width.is_some() || height.is_some() {
        return (width, height);
    }
    let Some((width, height)) = element
        .attr("data-original-dimensions")
        .and_then(|value| value.split_once('x'))
    else {
        return (None, None);
    };
    (image_dimension(Some(width)), image_dimension(Some(height)))
}

fn is_emoji(element: &Element) -> bool {
    has_class(element, "emoji")
}

fn emoji_name(element: &Element, value: &str) -> String {
    let name = element
        .attr("title")
        .or_else(|| element.attr("alt"))
        .unwrap_or(value)
        .trim_matches(':');
    if name.is_empty() || name.len() > MAX_EMOJI_NAME_BYTES {
        "emoji".to_owned()
    } else {
        name.to_owned()
    }
}

fn is_executable_element(name: &str) -> bool {
    matches!(
        name,
        "script" | "style" | "iframe" | "object" | "embed" | "template" | "svg" | "math"
    )
}

fn has_class(element: &Element, class: &str) -> bool {
    element.has_class(class, CaseSensitivity::AsciiCaseInsensitive)
}

fn language_hint(node: NodeRef<'_, Node>, element: &Element) -> Option<String> {
    element
        .attr("data-code-language")
        .filter(|language| !language.is_empty() && language.len() <= 64)
        .map(str::to_owned)
        .or_else(|| {
            element
                .classes()
                .chain(node.descendants().filter_map(|node| {
                    node.value().as_element().and_then(|element| {
                        element
                            .classes()
                            .find(|class| class.starts_with("language-"))
                    })
                }))
                .find_map(|class| class.strip_prefix("language-").map(str::to_owned))
                .filter(|language| !language.is_empty() && language.len() <= 64)
        })
}

fn coalesce_text(inline: Vec<InlineContent>) -> Vec<InlineContent> {
    let mut output = Vec::new();
    for item in inline {
        match item {
            InlineContent::Text(value) => {
                if let Some(InlineContent::Text(previous)) = output.last_mut() {
                    previous.push_str(&value);
                } else {
                    output.push(InlineContent::Text(value));
                }
            }
            other => output.push(other),
        }
    }
    output
}

fn block_is_empty(block: &ContentBlock) -> bool {
    match block {
        ContentBlock::Paragraph(inline) => inline.iter().all(|item| match item {
            InlineContent::Text(value) => value.trim().is_empty(),
            _ => false,
        }),
        ContentBlock::Quote(blocks) => blocks.is_empty(),
        ContentBlock::List { items, .. } => items.is_empty(),
        ContentBlock::Code { value, .. } => value.is_empty(),
        ContentBlock::Image { .. } | ContentBlock::Unsupported { .. } => false,
    }
}

fn unsafe_block() -> ContentBlock {
    ContentBlock::Unsupported {
        summary: "Unsafe content was omitted".to_owned(),
    }
}

fn limit_block() -> ContentBlock {
    ContentBlock::Unsupported {
        summary: "Message content exceeded safe display limits".to_owned(),
    }
}

fn readable_text_fallback(html: &str) -> String {
    let mut text = String::new();
    let mut inside_tag = false;
    for character in html.chars().take(2_048) {
        match character {
            '<' => inside_tag = true,
            '>' => inside_tag = false,
            _ if !inside_tag => text.push(character),
            _ => {}
        }
    }
    let text = text.trim();
    if text.is_empty() {
        "Unsupported message content".to_owned()
    } else {
        text.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::{ContentBlock, InlineContent, MAX_INPUT_BYTES, parse_zulip_html};

    #[test]
    fn parses_zulip_blocks_and_inline_semantics() {
        let html = r#"
            <p>Hello <a href="https://zulip.com/help">Zulip</a>
            <span class="user-mention" data-user-id="42">@Maya Chen</span>
            <img class="emoji" alt=":tada:" title=":tada:" src="/emoji.png"></p>
            <blockquote><p>Quoted text</p></blockquote>
            <ul><li><p>First</p></li><li>Second</li></ul>
            <ol><li>One</li></ol>
            <pre><code class="language-rust">fn main() {}</code></pre>
            <img src="/user_uploads/image.png" alt="Preview" width="640" height="360">
        "#;
        let blocks = parse_zulip_html(html);
        assert!(matches!(
            &blocks[0],
            ContentBlock::Paragraph(inline)
                if inline.iter().any(|item| matches!(
                    item,
                    InlineContent::Link { label, url }
                        if label == "Zulip" && url == "https://zulip.com/help"
                )) && inline.iter().any(|item| matches!(
                    item,
                    InlineContent::Mention { display_name, user_id: 42 }
                        if display_name == "Maya Chen"
                )) && inline.iter().any(|item| matches!(
                    item,
                    InlineContent::Emoji { name, value }
                        if name == "tada" && value == ":tada:"
                ))
        ));
        assert!(matches!(&blocks[1], ContentBlock::Quote(items) if !items.is_empty()));
        assert!(matches!(
            &blocks[2],
            ContentBlock::List { items, ordered: false } if items.len() == 2
        ));
        assert!(matches!(
            &blocks[3],
            ContentBlock::List { items, ordered: true } if items.len() == 1
        ));
        assert!(matches!(
            &blocks[4],
            ContentBlock::Code { language: Some(language), value }
                if language == "rust" && value == "fn main() {}"
        ));
        assert!(matches!(
            &blocks[5],
            ContentBlock::Image { url, alt, width: Some(640), height: Some(360) }
                if url == "/user_uploads/image.png" && alt == "Preview"
        ));
    }

    #[test]
    fn strips_executable_markup_and_unsafe_schemes() {
        let blocks = parse_zulip_html(
            r#"<p><a href="javascript:alert(1)">safe label</a></p>
               <p><a href="https://zulip.com">visible<script>hidden()</script></a>
                  <a href="//attacker.example">network label</a></p>
               <script>steal()</script><img src="data:text/html,bad" alt="bad">"#,
        );
        assert!(matches!(
            &blocks[0],
            ContentBlock::Paragraph(items)
                if items == &vec![InlineContent::Text("safe label".to_owned())]
        ));
        assert!(
            blocks
                .iter()
                .all(|block| !format!("{block:?}").contains("javascript"))
        );
        let debug = format!("{blocks:?}");
        assert!(debug.contains("visible"));
        assert!(debug.contains("network label"));
        assert!(!debug.contains("hidden()"));
        assert!(!debug.contains("attacker.example"));
        assert!(
            blocks
                .iter()
                .any(|block| matches!(block, ContentBlock::Unsupported { .. }))
        );
    }

    #[test]
    fn malformed_and_unknown_markup_keeps_readable_text() {
        let malformed = parse_zulip_html("<p>Hello <strong>world<ul><li>one<li>two");
        let debug = format!("{malformed:?}");
        assert!(debug.contains("Hello"));
        assert!(debug.contains("world"));
        assert!(debug.contains("one"));

        let unknown = parse_zulip_html("<table><tr><td>Readable cells</td></tr></table>");
        assert!(matches!(
            &unknown[0],
            ContentBlock::Unsupported { summary } if summary.contains("Readable cells")
        ));
    }

    #[test]
    fn parses_current_zulip_emoji_code_and_image_markup() {
        let blocks = parse_zulip_html(
            r#"<p><span aria-label="waving hand" class="emoji emoji-1f44b"
                    role="img" title="wave">:wave:</span>
                <img alt=":zulip:" class="emoji" title="zulip"
                    src="/static/generated/emoji/zulip.png"></p>
                <div class="codehilite" data-code-language="python">
                    <pre><code>print("safe")</code></pre>
                </div>
                <div class="message_inline_image">
                    <a href="/user_uploads/original.png">
                        <img data-original-dimensions="1920x1080"
                            src="/user_uploads/thumbnail.webp" alt="Preview">
                    </a>
                </div>"#,
        );

        assert!(matches!(
            &blocks[0],
            ContentBlock::Paragraph(content)
                if content.iter().any(|item| matches!(
                    item,
                    InlineContent::Emoji { name, value }
                        if name == "wave" && value == ":wave:"
                )) && content.iter().any(|item| matches!(
                    item,
                    InlineContent::Emoji { name, value }
                        if name == "zulip" && value == ":zulip:"
                ))
        ));
        assert!(matches!(
            &blocks[1],
            ContentBlock::Code { language: Some(language), value }
                if language == "python" && value.contains("print(\"safe\")")
        ));
        assert!(matches!(
            &blocks[2],
            ContentBlock::Image {
                url,
                alt,
                width: Some(1920),
                height: Some(1080),
            } if url == "/user_uploads/thumbnail.webp" && alt == "Preview"
        ));
    }

    #[test]
    fn input_and_tree_output_are_bounded() {
        let oversized = "x".repeat(MAX_INPUT_BYTES + 1);
        assert_eq!(
            parse_zulip_html(&oversized),
            vec![ContentBlock::Unsupported {
                summary: "Message content exceeded safe display limits".to_owned(),
            }]
        );

        let many = "<p>item</p>".repeat(300);
        assert_eq!(
            parse_zulip_html(&many),
            vec![ContentBlock::Unsupported {
                summary: "Message content exceeded safe display limits".to_owned(),
            }]
        );
    }
}
