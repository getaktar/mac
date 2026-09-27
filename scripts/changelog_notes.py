"""Prints one version's CHANGELOG.md section as simple HTML, for the
release notes Sparkle shows in its update window (see release.sh).

Usage: python3 scripts/changelog_notes.py <version>
"""
import html, re, sys

version = sys.argv[1]
text = open("CHANGELOG.md", encoding="utf-8").read()
match = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.S | re.M)
if not match:
    sys.exit(f"CHANGELOG.md has no section for {version}")

def inline(value):
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(value))

out, item, in_list = [], None, False
def flush():
    global item
    if item is not None:
        out.append(f"<li>{inline(item)}</li>")
        item = None

for line in match.group(1).splitlines():
    if line.startswith("### "):
        flush()
        if in_list:
            out.append("</ul>")
            in_list = False
        out.append(f"<h3>{inline(line[4:].strip())}</h3>")
    elif line.startswith("- "):
        flush()
        if not in_list:
            out.append("<ul>")
            in_list = True
        item = line[2:].strip()
    elif line.strip() and item is not None:
        item += " " + line.strip()
flush()
if in_list:
    out.append("</ul>")
print("\n".join(out))
