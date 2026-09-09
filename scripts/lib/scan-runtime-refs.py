#!/usr/bin/env python3
"""Scan a runtime tree for LOADS of the vendored upstream-reference tree.

Used by `scripts/lvim-smoke.sh`'s phase 9.3 guard. Lives in its own file rather
than inline in that script so it can be exercised directly by
`check_phase_93_scanner_lexing`, which feeds it synthetic fixtures covering the
lexing edge cases -- an inline heredoc cannot be tested without running the
whole suite, and a subtle bug in it (an infinite loop on an empty here-doc line)
already slipped through once.

Usage:  scan-runtime-refs.py <path> [<path> ...]
Exit:   0 clean, 1 reference found (printed to stdout), 2 scan failed.

Comments are stripped before matching, because comments citing
`references/<name>/lua/...` are what `references/README.md` asks contributors to
write. Strings are NOT stripped: a path in a string literal is a real load.
"""

import io, os, sys

NAME = "CK" + "LunarVim"


def blank_lua_comments(text):
    """Replace Lua comment text with spaces, preserving every newline.

    A real scanner is needed, not a line split on "--": Lua string literals can
    contain "--" (`local sep = "--"`), and splitting there erases the rest of
    the line, which is exactly where a `dofile("references/<name>/...")` could
    hide. So track string state and only treat "--" as a comment when we are
    not inside one.

    Handles: short strings with backslash escapes, long strings [[ ]] / [=[ ]=],
    line comments, and long comments --[[ ]] / --[==[ ]==]. Lua long brackets do
    not nest, so a level-matched close is unambiguous.
    """
    out = []
    i, n = 0, len(text)

    def keep(seg):
        out.append(seg)

    def blank(seg):
        # Preserve newlines so reported line numbers stay accurate.
        out.append("".join(c if c == "\n" else " " for c in seg))

    def long_bracket_at(pos):
        # Returns the level if text[pos:] opens a long bracket, else None.
        if text[pos] != "[":
            return None
        j = pos + 1
        level = 0
        while j < n and text[j] == "=":
            level += 1
            j += 1
        if j < n and text[j] == "[":
            return level
        return None

    while i < n:
        ch = text[i]

        # Comment (line or long) -- only reachable outside a string.
        if ch == "-" and text.startswith("--", i):
            level = long_bracket_at(i + 2) if i + 2 < n else None
            if level is not None:
                close = "]" + "=" * level + "]"
                end_idx = text.find(close, i + 2)
                stop = n if end_idx == -1 else end_idx + len(close)
                blank(text[i:stop])
                i = stop
                continue
            end_idx = text.find("\n", i)
            stop = n if end_idx == -1 else end_idx
            blank(text[i:stop])
            i = stop
            continue

        # Long string: content is code, keep it.
        level = long_bracket_at(i)
        if level is not None:
            close = "]" + "=" * level + "]"
            end_idx = text.find(close, i)
            stop = n if end_idx == -1 else end_idx + len(close)
            keep(text[i:stop])
            i = stop
            continue

        # Short string: keep, honouring escapes so an escaped quote does not
        # end it early.
        if ch in ("'", '"'):
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == ch or text[j] == "\n":
                    j += 1
                    break
                j += 1
            keep(text[i:j])
            i = j
            continue

        keep(ch)
        i += 1

    return "".join(out)


def strip_sh(text):
    """Blank shell comment text, honouring quoting, escapes and here-docs.

    A naive "blank from the first unquoted # to end of line" is bypassable:
    `printf "x\\" # y"; . references/<name>/init.sh` closes the double quote at
    an ESCAPED quote, treats the rest as a comment, and erases the real
    `source` that follows. So escapes have to be modelled.

    Here-doc bodies are blanked wholesale. They are data, not executed code,
    and this repository's own scripts embed prose and Python inside them --
    scanning them produced false positives. The trade-off is a payload smuggled
    through `source /dev/stdin <<EOF`, which no accidental regression looks
    like.
    """
    out = []
    i, n = 0, len(text)
    quote = None            # None, "'" or '"'
    in_comment = False
    pending_heredocs = []   # terminators awaiting their body
    heredoc = None          # (terminator, strip_tabs) while inside a body

    def at_line_start(pos):
        return pos == 0 or text[pos - 1] == "\n"

    while i < n:
        ch = text[i]

        # Inside a here-doc body: blank until the terminator line.
        if heredoc is not None:
            line_end = text.find("\n", i)
            if line_end == -1:
                line_end = n
            line = text[i:line_end]
            candidate = line.lstrip("\t") if heredoc[1] else line
            out.append(" " * len(line))
            # Consume the newline here too. `text.find("\n", i)` returns `i`
            # itself when `i` already points AT a newline (an empty line in the
            # body), so assigning `i = line_end` would not advance and the scan
            # would spin forever. Advancing past the terminator is what makes
            # this loop always make progress.
            if line_end < n:
                out.append("\n")
                i = line_end + 1
            else:
                i = n
            if candidate.strip() == heredoc[0]:
                heredoc = None
            continue

        if ch == "\n":
            out.append(ch)
            in_comment = False
            quote = None
            i += 1
            if pending_heredocs:
                heredoc = pending_heredocs.pop(0)
            continue

        if in_comment:
            out.append(" ")
            i += 1
            continue

        if quote == "'":
            out.append(ch)
            if ch == "'":
                quote = None
            i += 1
            continue

        if quote == '"':
            if ch == "\\" and i + 1 < n:
                out.append(text[i : i + 2])
                i += 2
                continue
            out.append(ch)
            if ch == '"':
                quote = None
            i += 1
            continue

        # Unquoted.
        if ch == "\\" and i + 1 < n:
            out.append(text[i : i + 2])
            i += 2
            continue

        if ch in ("'", '"'):
            quote = ch
            out.append(ch)
            i += 1
            continue

        # Here-doc introducer: <<EOF, <<-EOF, <<'EOF', <<"EOF".
        if text.startswith("<<", i) and not text.startswith("<<<", i):
            j = i + 2
            strip_tabs = False
            if j < n and text[j] == "-":
                strip_tabs = True
                j += 1
            while j < n and text[j] in " \t":
                j += 1
            term_quote = None
            if j < n and text[j] in ("'", '"'):
                term_quote = text[j]
                j += 1
            k = j
            while k < n and (text[k].isalnum() or text[k] in "_-."):
                k += 1
            term = text[j:k]
            if term_quote and k < n and text[k] == term_quote:
                k += 1
            if term:
                pending_heredocs.append((term, strip_tabs))
                out.append(text[i:k])
                i = k
                continue

        if ch == "#":
            # `#` only starts a comment at a word boundary; `printf x#y` does not.
            if i == 0 or text[i - 1] in " \t\n;&|(" or at_line_start(i):
                in_comment = True
                out.append(" ")
                i += 1
                continue

        out.append(ch)
        i += 1

    return "".join(out)


def walk_error(exc):
    sys.stderr.write("scan error: %s\n" % exc)
    raise SystemExit(2)


targets = []
seen_dirs = set()
for root in sys.argv[1:]:
    if os.path.isfile(root):
        targets.append(root)
        continue
    if not os.path.exists(root):
        sys.stderr.write("scan error: missing scan root %s\n" % root)
        raise SystemExit(2)
    # followlinks=True: a symlinked subtree under lua/ is still loaded at
    # runtime, so it must still be scanned. That reintroduces the possibility of
    # a symlink cycle, so directories are tracked by (device, inode) and visited
    # at most once.
    for dirpath, dirnames, filenames in os.walk(root, onerror=walk_error, followlinks=True):
        try:
            st = os.stat(dirpath)
            key = (st.st_dev, st.st_ino)
        except OSError as exc:
            sys.stderr.write("scan error: %s: %s\n" % (dirpath, exc))
            raise SystemExit(2)
        if key in seen_dirs:
            dirnames[:] = []
            continue
        seen_dirs.add(key)
        for fn in filenames:
            targets.append(os.path.join(dirpath, fn))

hits = []
for path in sorted(set(targets)):
    # Decode with replacement rather than strictly. Lua source is byte-oriented:
    # a perfectly loadable .lua file can carry an invalid UTF-8 byte inside a
    # comment or string and still run `dofile(...)`. Treating a decode failure
    # as "binary, skip it" turned that into a silent bypass of this guard.
    try:
        with io.open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        sys.stderr.write("scan error: %s: %s\n" % (path, exc))
        raise SystemExit(2)
    if NAME not in text:
        continue
    stripped = blank_lua_comments(text) if path.endswith(".lua") else strip_sh(text)
    for num, line in enumerate(stripped.split("\n"), 1):
        if NAME in line:
            hits.append("%s:%d:%s" % (path, num, line.strip()))

sys.stdout.write("\n".join(hits))
raise SystemExit(1 if hits else 0)
