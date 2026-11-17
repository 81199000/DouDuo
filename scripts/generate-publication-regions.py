"""Generate the bundled offline code lookup from province-city-china 9.0.0.

Pass the directory containing the published province, city and area JSON.
Source: https://github.com/uiwjs/province-city-china/tree/v9.0.0
MIT: DouDuo/ProvinceCityChina-MIT.txt
See docs/publication-region.md for reproducible download/checksum instructions.
County codes resolve to their prefecture (or province for municipalities).
"""
import json
from pathlib import Path
import re
import sys


def generate(source):
    def rows(name):
        return json.loads((source / f"{name}.json").read_text())

    provinces = {row["province"]: row["name"].removesuffix("省") for row in rows("province")}
    names = {key + "0000": name for key, name in provinces.items()}
    for row in rows("city"):
        province = provinces[row["province"]]
        names[row["code"]] = province if "行政区划" in row["name"] else f"{province}·{row['name']}"
    for row in rows("area"):
        code = row["code"]
        province = provinces[row["province"]]
        if row["city"] == "90" and code[:4] + "00" in names:
            label = f"{province}·{row['name']}" if row["name"].endswith("市") else province
        else:
            label = names.get(code[:4] + "00", province)
        names.setdefault(code, label)
    assert all(re.fullmatch(r"[0-9]{6}", code) and name for code, name in names.items())
    return dict(sorted(names.items()))


if __name__ == "__main__":
    names = generate(Path(sys.argv[1]))
    output = Path(__file__).resolve().parents[1] / "DouDuo" / "DouyinPublicationRegions.json"
    output.write_text(json.dumps(names, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{len(names)} codes; {output.stat().st_size} bytes")
