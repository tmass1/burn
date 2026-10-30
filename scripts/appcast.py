#!/usr/bin/env python3
"""Writes Burn's Sparkle appcast: one item, the release being cut, with its notes as HTML.

    scripts/appcast.py --version 2.1.0 --build 5 --url https://…/Burn.zip --signature <edSignature> --length 4086602 \
        --notes docs/releases/2.1.0.md --out build/appcast.xml

Sparkle only needs the newest item; the archive's EdDSA signature and length come from `sign_update`.
"""
import argparse
import datetime
import html
import re
from email.utils import format_datetime


def inline(text):
    """The Markdown the release notes use inside a line: code, bold, italics and links."""
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<i>\1</i>", text)
    return re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a href="\2">\1</a>', text)


def notes_html(markdown):
    """Paragraphs, headings and bullet lists — enough for docs/releases/*.md."""
    out, items, para = [], [], []

    def flush():
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>")
            para.clear()
        if items:
            out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items.clear()

    for line in markdown.splitlines():
        stripped = line.strip()
        if not stripped:
            flush()
        elif stripped.startswith("#"):
            flush()
            level = min(len(stripped) - len(stripped.lstrip("#")) + 1, 4)
            out.append(f"<h{level}>{inline(stripped.lstrip('#').strip())}</h{level}>")
        elif re.match(r"^[-*] ", stripped):
            if para:
                flush()
            items.append(stripped[2:])
        elif items and line.startswith(("  ", "\t")):
            items[-1] += " " + stripped
        else:
            if items:
                flush()
            para.append(stripped)
    flush()
    return "\n".join(out)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--signature", required=True)
    p.add_argument("--length", required=True)
    p.add_argument("--notes", required=True)
    p.add_argument("--minimum-system", default="14.0")
    p.add_argument("--out", required=True)
    a = p.parse_args()

    with open(a.notes, encoding="utf-8") as f:
        body = notes_html(f.read())
    style = ("<style>body{font:13px -apple-system,sans-serif;line-height:1.45}"
             "code{font:12px ui-monospace,Menlo,monospace}ul{padding-left:18px}</style>")
    item = f"""    <item>
      <title>Burn {html.escape(a.version)}</title>
      <pubDate>{format_datetime(datetime.datetime.now(datetime.timezone.utc))}</pubDate>
      <sparkle:version>{html.escape(a.build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(a.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(a.minimum_system)}</sparkle:minimumSystemVersion>
      <description><![CDATA[{style}
{body}]]></description>
      <enclosure url="{html.escape(a.url)}" length="{html.escape(a.length)}" type="application/octet-stream"
                 sparkle:edSignature="{html.escape(a.signature)}"/>
    </item>"""
    feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Burn</title>
    <link>https://github.com/tmass1/burn</link>
    <description>Updates to Burn, the menu-bar meter for AI plan limits.</description>
    <language>en</language>
{item}
  </channel>
</rss>
"""
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(feed)


if __name__ == "__main__":
    main()
