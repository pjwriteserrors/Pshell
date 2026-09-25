#!/usr/bin/env bash
# Arch Linux news as TSV: published (epoch ms) <TAB> title <TAB> link
# Exits non-zero when the feed could not be fetched or parsed.
set -uo pipefail

feed=$(curl -fsSL --max-time 20 https://archlinux.org/feeds/news/) || exit 1

python3 -c '
import sys
import xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime

root = ET.fromstring(sys.stdin.read())
for item in root.iter("item"):
    title = " ".join((item.findtext("title") or "").split())
    link = (item.findtext("link") or "").strip()
    try:
        stamp = int(parsedate_to_datetime(item.findtext("pubDate") or "").timestamp() * 1000)
    except (TypeError, ValueError):
        continue
    if title and link:
        print(f"{stamp}\t{title}\t{link}")
' <<<"$feed"
