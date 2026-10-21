"""Terminal text geometry. Colors and display policy are supplied by style.sh."""

import re
import sys
import unicodedata


def safe_text(value, ascii_only=False, escape_backslash=True):
    result = ""
    for char in str(value):
        if char == "\\" and escape_backslash:
            result += "\\\\"
        elif unicodedata.category(char).startswith("C") or (ascii_only and ord(char) > 127):
            result += ("\\U%08x" if ord(char) > 65535 else "\\u%04x" if ord(char) > 255 else "\\x%02x") % ord(char)
        else:
            result += char
    return result


def cell_width(char):
    if unicodedata.combining(char):
        return 0
    return 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1


def wrap(text, width, ascii_only=False):
    lines, current, used = [], "", 0
    for char in safe_text(text, ascii_only):
        cells = cell_width(char)
        if used + cells > width:
            lines.append(current)
            current, used = "", 0
        current += char
        used += cells
    lines.append(current)
    return lines


SGR = re.compile(r"(\x1b\[[0-9;]*m)")


def render(cells):
    output, previous = "", ""
    for char, _width, style in cells:
        if style != previous:
            output += ("\x1b[0m" if previous else "") + style
            previous = style
        output += char
    return output + ("\x1b[0m" if previous else "")


def wrap_styled(text, width, indent):
    cells, style = [], ""
    for part in SGR.split(text):
        if SGR.fullmatch(part):
            if part in ("\x1b[m", "\x1b[0m"):
                style = ""
            else:
                style += part
        else:
            # Reports also contain shell-quoted next steps. Geometry must not
            # change their literal escapes; the reviewer escapes raw identities.
            cells.extend((char, cell_width(char), style)
                         for char in safe_text(part, escape_backslash=False))
    if not cells:
        return [""]
    result = []
    while cells:
        used, cut, space, content = 0, 0, None, False
        for index, (char, size, _style) in enumerate(cells):
            if used + size > width:
                break
            used += size
            cut = index + 1
            if char == " " and content:
                space = index
            elif char != " ":
                content = True
        if cut == len(cells):
            result.append(render(cells))
            break
        if space is not None and space > indent:
            cut = space + 1
        cut = max(1, cut)
        result.append(render(cells[:cut]))
        cells = cells[cut:]
        if cells:
            cells = [(" ", 1, "")] * indent + cells
    return result


def main():
    width = max(4, int(sys.argv[1]) - 1)
    indent = min(int(sys.argv[2]), width - 2)
    for line in sys.stdin:
        for wrapped in wrap_styled(line.rstrip("\n"), width, indent):
            print(wrapped)


if __name__ == "__main__":
    main()
