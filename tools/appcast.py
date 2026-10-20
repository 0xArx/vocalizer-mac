#!/usr/bin/env python3
"""Adds a release to the Sparkle appcast (newest first). Used by scripts/publish.sh.

  appcast.py <appcast.xml> <build> <version> <download url> '<sparkle:edSignature=... length=...>' <notes>
Notes: one change per line; rendered as a list in Sparkle's update window.
"""
import html, os, sys
from email.utils import formatdate

path, build, version, url, sig, notes = sys.argv[1:7]
items = "\n".join(f"          <li>{html.escape(l.strip().lstrip('-').strip())}</li>" for l in notes.splitlines() if l.strip())
item = f"""    <item>
      <title>Vocalizer {version}</title>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <description><![CDATA[
        <ul>
{items}
        </ul>
      ]]></description>
      <enclosure url="{url}" {sig} type="application/octet-stream"/>
    </item>
"""
head = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Vocalizer</title>
    <link>https://getvocalizer.com/appcast.xml</link>
    <description>Updates for Vocalizer for Mac</description>
    <language>en</language>
"""
tail = "  </channel>\n</rss>\n"
body = ""
if os.path.exists(path):
    old = open(path).read()
    if f"<sparkle:version>{build}</sparkle:version>" in old:
        sys.exit(f"build {build} is already in {path}")
    start, end = old.find("    <item>"), old.rfind("  </channel>")
    body = old[start:end] if start != -1 else ""
open(path, "w").write(head + item + body + tail)
print(f"appcast: added {version} ({build})")
