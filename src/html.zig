//! A forgiving HTML parser: enough tree for the Qalam portal's server-rendered pages. It skips
//! scripts and styles, knows void elements, and closes `li`, `p`, `tr`, `td`/`th` and `option`
//! implicitly the way browsers do. Unknown end tags are ignored.
const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig");

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Node = struct {
    /// Lowercase tag name; empty for text nodes and the document.
    tag: []const u8 = "",
    /// Decoded text, for text nodes.
    data: []const u8 = "",
    attrs: []const Attr = &.{},
    children: std.ArrayList(*Node) = .empty,
    parent: ?*Node = null,

    pub fn isText(n: *const Node) bool {
        return n.tag.len == 0 and n.parent != null and n.children.items.len == 0 and n.data.len > 0;
    }

    pub fn is(n: *const Node, tag: []const u8) bool {
        return std.mem.eql(u8, n.tag, tag);
    }

    pub fn attr(n: *const Node, name: []const u8) ?[]const u8 {
        for (n.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }

    pub fn hasClass(n: *const Node, class: []const u8) bool {
        const v = n.attr("class") orelse return false;
        var it = std.mem.tokenizeAny(u8, v, " \t\r\n");
        while (it.next()) |c| if (std.mem.eql(u8, c, class)) return true;
        return false;
    }

    /// All text below this node, whitespace collapsed, pieces joined with spaces.
    pub fn textContent(n: *const Node, gpa: Allocator) []const u8 {
        var buf: std.ArrayList(u8) = .empty;
        collectText(n, gpa, &buf);
        return text.collapse(gpa, buf.items);
    }

    fn collectText(n: *const Node, gpa: Allocator, buf: *std.ArrayList(u8)) void {
        if (n.tag.len == 0 and n.data.len > 0) {
            buf.append(gpa, ' ') catch {};
            buf.appendSlice(gpa, n.data) catch {};
            return;
        }
        for (n.children.items) |c| collectText(c, gpa, buf);
    }

    /// Element children only.
    pub fn elements(n: *const Node, gpa: Allocator) []const *Node {
        var out: std.ArrayList(*Node) = .empty;
        for (n.children.items) |c| if (c.tag.len > 0) out.append(gpa, c) catch {};
        return out.items;
    }

    /// Element children with this tag.
    pub fn childrenTagged(n: *const Node, gpa: Allocator, tag: []const u8) []const *Node {
        var out: std.ArrayList(*Node) = .empty;
        for (n.children.items) |c| if (c.is(tag)) out.append(gpa, c) catch {};
        return out.items;
    }

    /// Every descendant element matching `pred`, in document order.
    pub fn findAll(n: *const Node, gpa: Allocator, ctx: anytype, comptime pred: fn (@TypeOf(ctx), *const Node) bool) []const *Node {
        var out: std.ArrayList(*Node) = .empty;
        walk(n, gpa, ctx, pred, &out);
        return out.items;
    }

    fn walk(n: *const Node, gpa: Allocator, ctx: anytype, comptime pred: fn (@TypeOf(ctx), *const Node) bool, out: *std.ArrayList(*Node)) void {
        for (n.children.items) |c| {
            if (c.tag.len == 0) continue;
            if (pred(ctx, c)) out.append(gpa, c) catch {};
            walk(c, gpa, ctx, pred, out);
        }
    }

    pub fn first(n: *const Node, gpa: Allocator, ctx: anytype, comptime pred: fn (@TypeOf(ctx), *const Node) bool) ?*Node {
        const all = n.findAll(gpa, ctx, pred);
        return if (all.len > 0) all[0] else null;
    }

    pub fn byTag(n: *const Node, gpa: Allocator, tag: []const u8) []const *Node {
        return n.findAll(gpa, tag, matchTag);
    }

    pub fn byClass(n: *const Node, gpa: Allocator, class: []const u8) []const *Node {
        return n.findAll(gpa, class, matchClass);
    }

    pub fn firstClass(n: *const Node, gpa: Allocator, class: []const u8) ?*Node {
        return n.first(gpa, class, matchClass);
    }

    pub fn firstTag(n: *const Node, gpa: Allocator, tag: []const u8) ?*Node {
        return n.first(gpa, tag, matchTag);
    }

    pub fn byId(n: *const Node, gpa: Allocator, id: []const u8) ?*Node {
        return n.first(gpa, id, matchId);
    }

    /// The nearest ancestor with this tag.
    pub fn ancestor(n: *const Node, tag: []const u8) ?*Node {
        var p = n.parent;
        while (p) |x| : (p = x.parent) if (x.is(tag)) return x;
        return null;
    }

    pub fn ancestorWithClass(n: *const Node, class: []const u8) ?*Node {
        var p = n.parent;
        while (p) |x| : (p = x.parent) if (x.hasClass(class)) return x;
        return null;
    }

    /// The element siblings after this one, in order.
    pub fn nextSiblings(n: *const Node, gpa: Allocator) []const *Node {
        const p = n.parent orelse return &.{};
        var out: std.ArrayList(*Node) = .empty;
        var seen = false;
        for (p.children.items) |c| {
            if (c == n) {
                seen = true;
                continue;
            }
            if (seen and c.tag.len > 0) out.append(gpa, c) catch {};
        }
        return out.items;
    }
};

pub fn matchTag(tag: []const u8, n: *const Node) bool {
    return n.is(tag);
}
pub fn matchClass(class: []const u8, n: *const Node) bool {
    return n.hasClass(class);
}
pub fn matchId(id: []const u8, n: *const Node) bool {
    const v = n.attr("id") orelse return false;
    return std.mem.eql(u8, v, id);
}

const void_tags = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" };
const p_closers = [_][]const u8{ "p", "div", "ul", "ol", "table", "h1", "h2", "h3", "h4", "h5", "h6", "form", "section", "header", "footer", "nav", "pre", "blockquote" };

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

const Parser = struct {
    gpa: Allocator,
    src: []const u8,
    i: usize = 0,
    root: *Node,
    stack: std.ArrayList(*Node) = .empty,

    fn current(p: *Parser) *Node {
        return p.stack.items[p.stack.items.len - 1];
    }

    fn append(p: *Parser, n: *Node) !void {
        const parent = p.current();
        n.parent = parent;
        try parent.children.append(p.gpa, n);
    }

    fn addText(p: *Parser, raw: []const u8) !void {
        if (raw.len == 0) return;
        const n = try p.gpa.create(Node);
        n.* = .{ .data = text.decodeEntities(p.gpa, raw) };
        try p.append(n);
    }

    /// Pops up to and including the nearest open `tag`, unless a `stop` tag comes first.
    fn closeTo(p: *Parser, tags: []const []const u8, stop: []const []const u8) void {
        var k = p.stack.items.len;
        while (k > 1) {
            k -= 1;
            const t = p.stack.items[k].tag;
            if (inList(tags, t)) {
                p.stack.items.len = k;
                return;
            }
            if (inList(stop, t)) return;
        }
    }

    fn implicitClose(p: *Parser, tag: []const u8) void {
        if (std.mem.eql(u8, tag, "li")) p.closeTo(&.{"li"}, &.{ "ul", "ol", "menu" });
        if (std.mem.eql(u8, tag, "option")) p.closeTo(&.{"option"}, &.{"select"});
        if (std.mem.eql(u8, tag, "tr")) p.closeTo(&.{"tr"}, &.{ "table", "thead", "tbody", "tfoot" });
        if (std.mem.eql(u8, tag, "td") or std.mem.eql(u8, tag, "th")) p.closeTo(&.{ "td", "th" }, &.{ "tr", "table" });
        if (std.mem.eql(u8, tag, "thead") or std.mem.eql(u8, tag, "tbody") or std.mem.eql(u8, tag, "tfoot"))
            p.closeTo(&.{ "thead", "tbody", "tfoot" }, &.{"table"});
        if (inList(&p_closers, tag)) p.closeTo(&.{"p"}, &.{ "div", "td", "th", "li", "table", "body" });
    }

    fn run(p: *Parser) !void {
        try p.stack.append(p.gpa, p.root);
        const s = p.src;
        var text_start: usize = 0;
        while (p.i < s.len) {
            if (s[p.i] != '<') {
                p.i += 1;
                continue;
            }
            const lt = p.i;
            if (std.mem.startsWith(u8, s[lt..], "<!--")) {
                try p.addText(s[text_start..lt]);
                const end = std.mem.findPos(u8, s, lt + 4, "-->") orelse s.len;
                p.i = @min(s.len, end + 3);
                text_start = p.i;
                continue;
            }
            if (lt + 1 < s.len and (s[lt + 1] == '!' or s[lt + 1] == '?')) {
                try p.addText(s[text_start..lt]);
                p.i = (std.mem.findScalarPos(u8, s, lt, '>') orelse s.len - 1) + 1;
                text_start = p.i;
                continue;
            }
            const closing = lt + 1 < s.len and s[lt + 1] == '/';
            const name_start = lt + 1 + @intFromBool(closing);
            if (name_start >= s.len or !std.ascii.isAlphabetic(s[name_start])) {
                p.i += 1;
                continue;
            }
            try p.addText(s[text_start..lt]);
            var j = name_start;
            while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '-' or s[j] == ':' or s[j] == '_')) j += 1;
            const tag = try std.ascii.allocLowerString(p.gpa, s[name_start..j]);
            if (closing) {
                p.i = (std.mem.findScalarPos(u8, s, j, '>') orelse s.len - 1) + 1;
                text_start = p.i;
                if (std.mem.eql(u8, tag, "p") or std.mem.eql(u8, tag, "br")) {} // tolerated below
                p.closeTo(&.{tag}, &.{});
                continue;
            }
            var attrs: std.ArrayList(Attr) = .empty;
            var self_closing = false;
            while (j < s.len) {
                while (j < s.len and std.ascii.isWhitespace(s[j])) j += 1;
                if (j >= s.len) break;
                if (s[j] == '>') {
                    j += 1;
                    break;
                }
                if (s[j] == '/') {
                    self_closing = true;
                    j += 1;
                    continue;
                }
                const an_start = j;
                while (j < s.len and !std.ascii.isWhitespace(s[j]) and s[j] != '=' and s[j] != '>' and !(s[j] == '/' and j + 1 < s.len and s[j + 1] == '>')) j += 1;
                const aname = try std.ascii.allocLowerString(p.gpa, s[an_start..j]);
                while (j < s.len and std.ascii.isWhitespace(s[j])) j += 1;
                var value: []const u8 = "";
                if (j < s.len and s[j] == '=') {
                    j += 1;
                    while (j < s.len and std.ascii.isWhitespace(s[j])) j += 1;
                    if (j < s.len and (s[j] == '"' or s[j] == '\'')) {
                        const q = s[j];
                        const vend = std.mem.findScalarPos(u8, s, j + 1, q) orelse s.len;
                        value = s[j + 1 .. vend];
                        j = @min(s.len, vend + 1);
                    } else {
                        const vs = j;
                        while (j < s.len and !std.ascii.isWhitespace(s[j]) and s[j] != '>') j += 1;
                        value = s[vs..j];
                    }
                }
                if (aname.len > 0) try attrs.append(p.gpa, .{ .name = aname, .value = text.decodeEntities(p.gpa, value) });
                self_closing = false;
            }
            p.i = j;
            text_start = j;
            p.implicitClose(tag);
            const n = try p.gpa.create(Node);
            n.* = .{ .tag = tag, .attrs = attrs.items };
            try p.append(n);
            if (std.mem.eql(u8, tag, "script") or std.mem.eql(u8, tag, "style")) {
                const end = std.ascii.findIgnoreCasePos(s, p.i, if (tag[1] == 'c') "</script" else "</style") orelse s.len;
                p.i = if (std.mem.findScalarPos(u8, s, end, '>')) |gt| gt + 1 else s.len;
                text_start = p.i;
                continue;
            }
            if (std.mem.eql(u8, tag, "title") or std.mem.eql(u8, tag, "textarea")) {
                const close_tag = if (tag[1] == 'i') "</title" else "</textarea";
                const end = std.ascii.findIgnoreCasePos(s, p.i, close_tag) orelse s.len;
                const t = try p.gpa.create(Node);
                t.* = .{ .data = text.decodeEntities(p.gpa, s[p.i..end]), .parent = n };
                if (t.data.len > 0) try n.children.append(p.gpa, t);
                p.i = if (std.mem.findScalarPos(u8, s, end, '>')) |gt| gt + 1 else s.len;
                text_start = p.i;
                continue;
            }
            if (!self_closing and !inList(&void_tags, tag)) try p.stack.append(p.gpa, n);
        }
        try p.addText(s[text_start..]);
    }
};

/// Parses a whole page. Everything is allocated in `gpa` (use an arena).
pub fn parse(gpa: Allocator, src: []const u8) !*Node {
    const root = try gpa.create(Node);
    root.* = .{};
    var p: Parser = .{ .gpa = gpa, .src = src, .root = root };
    try p.run();
    return root;
}

test "parses nested lists, tables and implicit closes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse(a,
        \\<html><head><title>T &amp; t</title><script>if (a<b) {}</script></head>
        \\<body><ul id="x"><li class="one two">A<li>B <b>bold</b></ul>
        \\<table><tr><td>1<td>2<tr><th>h</table><p>para<div>d</div><img src=x.png alt='i'><!-- c --></body>
    );
    const ul = doc.byId(a, "x").?;
    try std.testing.expectEqual(@as(usize, 2), ul.childrenTagged(a, "li").len);
    try std.testing.expect(ul.childrenTagged(a, "li")[0].hasClass("two"));
    try std.testing.expectEqualStrings("B bold", ul.childrenTagged(a, "li")[1].textContent(a));
    const rows = doc.byTag(a, "tr");
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(usize, 2), rows[0].childrenTagged(a, "td").len);
    try std.testing.expectEqualStrings("T & t", doc.byTag(a, "title")[0].textContent(a));
    try std.testing.expectEqualStrings("x.png", doc.byTag(a, "img")[0].attr("src").?);
    // <p> was closed by <div>, so the div is not inside it.
    try std.testing.expect(doc.byTag(a, "div")[0].parent.?.is("body"));
}
