#!/usr/bin/env python3
"""Scan XDG application directories for App Menu Editor."""

import json
import os
import sys


def unescape(value):
    if not value:
        return ""
    out = []
    i = 0
    while i < len(value):
        ch = value[i]
        if ch == "\\" and i + 1 < len(value):
            nxt = value[i + 1]
            if nxt == "s":
                out.append(" ")
                i += 2
                continue
            if nxt == "n":
                out.append("\n")
                i += 2
                continue
            if nxt == "t":
                out.append("\t")
                i += 2
                continue
            if nxt == "r":
                out.append("\r")
                i += 2
                continue
            if nxt == "\\":
                out.append("\\")
                i += 2
                continue
        out.append(ch)
        i += 1
    return "".join(out)


def parse_entry(path, is_user, locale):
    values = {}
    in_group = False
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                line = raw.rstrip("\n")
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                if stripped.startswith("["):
                    in_group = stripped == "[Desktop Entry]"
                    continue
                if not in_group:
                    continue
                eq = line.find("=")
                if eq <= 0:
                    continue
                values[line[:eq].strip()] = line[eq + 1:].strip()
    except OSError:
        return None

    if (values.get("Type") or "Application").lower() != "application":
        return None

    def localized(key):
        full = values.get(key + "[" + locale + "]")
        if full:
            return unescape(full)
        short = locale.split("_")[0].split("-")[0]
        if short:
            short_value = values.get(key + "[" + short + "]")
            if short_value:
                return unescape(short_value)
        return unescape(values.get(key))

    name = localized("Name")
    if not name:
        return None

    exec_value = unescape(values.get("Exec"))
    icon_value = unescape(values.get("Icon"))
    return {
        "filePath": path,
        "fileName": os.path.basename(path),
        "isUser": is_user,
        "name": name,
        "nameRaw": unescape(values.get("Name")) or name,
        "genericName": unescape(values.get("GenericName")),
        "comment": localized("Comment"),
        "exec": exec_value,
        "icon": icon_value,
        "categories": unescape(values.get("Categories")),
        "terminal": (values.get("Terminal") or "").lower() == "true",
        "noDisplay": (values.get("NoDisplay") or "").lower() == "true",
        "hidden": (values.get("Hidden") or "").lower() == "true",
    }


def main():
    if len(sys.argv) < 4:
        print("[]")
        return 1

    user_dir = os.path.abspath(sys.argv[1])
    locale = sys.argv[2] or "C"
    directories = sys.argv[3:]

    seen = set()
    result = []
    for directory in directories:
        try:
            entries = list(os.scandir(directory))
        except OSError:
            continue
        for entry in entries:
            name = entry.name
            if not name.endswith(".desktop") or name in seen:
                continue
            try:
                if not entry.is_file(follow_symlinks=True):
                    continue
            except OSError:
                continue
            seen.add(name)
            parsed = parse_entry(entry.path, os.path.dirname(entry.path) == user_dir, locale)
            if parsed is not None:
                result.append(parsed)

    json.dump(result, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
