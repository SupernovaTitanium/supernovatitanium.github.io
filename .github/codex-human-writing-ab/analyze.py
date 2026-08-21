#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--prompts", required=True)
    parser.add_argument("--checker", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    out = Path(args.out).resolve()
    prompts = json.loads(Path(args.prompts).read_text(encoding="utf-8"))
    manifest = json.loads((out / "run-manifest.json").read_text(encoding="utf-8"))
    checker = Path(args.checker).resolve()
    manifest_by_key = {(item["id"], item["condition"]): item for item in manifest}

    hard_patterns = {
        "colon": re.compile(r"[:：]"),
        "dash": re.compile(r"[—–]"),
        "pivot": re.compile(r"(?:不是|並非|并非)[^。！？\n]{0,90}而是"),
        "road_sign": re.compile(r"值得注意的是|需要指出的是|從某種意義上說|从某种意义上说"),
    }
    generic_markers = (
        "首先", "其次", "最後", "最后", "綜上", "综上",
        "總而言之", "总而言之", "這意味著", "这意味着",
        "核心是", "關鍵在於", "关键在于",
    )

    checker_dir = out / "checker"
    checker_dir.mkdir(exist_ok=True)
    records: list[dict[str, object]] = []
    for item in prompts:
        for condition in ("A", "B"):
            entry = manifest_by_key[(item["id"], condition)]
            final_path = out / entry["final_path"]
            text = final_path.read_text(encoding="utf-8").strip() if final_path.exists() else ""
            checker_text = ""
            checker_returncode: int | None = None
            if final_path.exists():
                completed = subprocess.run(
                    ["python3", str(checker), str(final_path)],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                checker_text = (completed.stdout + completed.stderr).strip()
                checker_returncode = completed.returncode
            (checker_dir / f"{item['id']}_{condition}.txt").write_text(
                checker_text + ("\n" if checker_text else ""), encoding="utf-8"
            )
            raw_text = (out / entry["raw_path"]).read_text(encoding="utf-8", errors="replace")
            records.append(
                {
                    **entry,
                    "prompt": item["prompt"],
                    "output": text,
                    "han_chars": len(re.findall(r"[\u4e00-\u9fff]", text)),
                    "sentence_count": len(re.findall(r"[。！？!?]", text)),
                    "paragraph_count": len([p for p in re.split(r"\n\s*\n", text) if p.strip()]),
                    "hard_pattern_counts": {
                        name: len(pattern.findall(text)) for name, pattern in hard_patterns.items()
                    },
                    "generic_marker_count": sum(text.count(marker) for marker in generic_markers),
                    "checker_returncode": checker_returncode,
                    "checker_output": checker_text,
                    "skill_path_seen_in_codex_events": "human-writing" in raw_text,
                    "skill_entry_seen_in_codex_events": "SKILL.md" in raw_text,
                }
            )

    metadata = {
        "design": {
            "conditions": {
                "A": "no installed writing skill and no skill invocation",
                "B": "full human-writing directory installed under ~/.agents/skills and explicitly invoked with $human-writing",
            },
            "fresh_session_per_cell": True,
            "same_model": True,
            "same_server": True,
            "server_temperature": 0,
            "server_seed": 424242,
            "checker_is_not_a_human_quality_judge": True,
        }
    }
    (out / "results.json").write_text(
        json.dumps(records, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (out / "metadata.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    pairs: dict[str, dict[str, dict[str, object]]] = {}
    for record in records:
        pairs.setdefault(str(record["id"]), {})[str(record["condition"])] = record
    lines = [
        "# Codex × human-writing A/B 原始結果",
        "",
        "A 沒有安裝或調用 skill。B 安裝完整 human-writing，並在同一提示詞前加上 `使用 $human-writing 完成以下任務。`。",
        "",
        "| 編號 | 場景 | A 沒用 | B 使用 |",
        "|---:|---|---|---|",
    ]
    for item in prompts:
        a = str(pairs[item["id"]]["A"]["output"]).replace("\n", "<br>").replace("|", "\\|")
        b = str(pairs[item["id"]]["B"]["output"]).replace("\n", "<br>").replace("|", "\\|")
        lines.append(f"| {item['id']} | {item['scene']} | {a} | {b} |")
    (out / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
