"""Turn SideTap's apps cache into a portable 中文名 ↔ bundle id 索引.

The cache stores "小红书 8.69.4" (name + version). A caller typing a name wants
"小红书" to work, so the version suffix is stripped; the raw row is kept under
`apps` for anything that needs it.
"""
import json
import re
from pathlib import Path

SRC = Path(r"C:\path\to\SideTap\.state\apps_cache.json")
OUT = Path(r"C:\path\to\PhoneKit\data\apps_index.json")

rows = json.loads(SRC.read_text(encoding="utf-8"))
by_name: dict[str, str] = {}
apps = []
for r in rows:
    bid = r["bundle_id"]
    raw = r.get("name", "")
    # "小红书 8.69.4" -> "小红书"; "网商银行 v10" -> "网商银行"
    clean = re.sub(r"\s+v?\d[\d.]*\s*$", "", raw).strip()
    apps.append({"bundle_id": bid, "name": clean, "raw": raw})
    if clean:
        by_name.setdefault(clean, bid)

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(
    json.dumps({"note": "中文名 → bundle id，来自本机已装 App。换机后用 `phone.cmd apps` 重建。",
                "by_name": by_name, "apps": apps},
               ensure_ascii=False, indent=1),
    encoding="utf-8",
)
print(f"{len(apps)} apps, {len(by_name)} named -> {OUT}")
