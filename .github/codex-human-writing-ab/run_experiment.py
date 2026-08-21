#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--prompts", required=True)
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--timeout", type=int, default=180)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    work = Path(args.work).resolve()
    out = Path(args.out).resolve()
    prompts = json.loads(Path(args.prompts).read_text(encoding="utf-8"))
    conditions = {
        "A": {
            "home": work / "home-A",
            "cwd": work / "work-A",
            "prefix": "",
        },
        "B": {
            "home": work / "home-B",
            "cwd": work / "work-B",
            "prefix": "使用 $human-writing 完成以下任務。\n\n",
        },
    }

    for subdir in ("raw", "stderr", "final"):
        (out / subdir).mkdir(parents=True, exist_ok=True)

    manifest: list[dict[str, object]] = []
    for item in prompts:
        for condition, spec in conditions.items():
            prompt = spec["prefix"] + item["prompt"]
            stem = f"{item['id']}_{condition}"
            raw_path = out / "raw" / f"{stem}.jsonl"
            err_path = out / "stderr" / f"{stem}.txt"
            final_path = out / "final" / f"{stem}.txt"
            env = os.environ.copy()
            env["HOME"] = str(spec["home"])
            env["CODEX_HOME"] = str(spec["home"] / ".codex")
            command = [
                args.codex,
                "exec",
                "--ephemeral",
                "--skip-git-repo-check",
                "--sandbox",
                "read-only",
                "--color",
                "never",
                "--json",
                "--output-last-message",
                str(final_path),
                "-C",
                str(spec["cwd"]),
                "-",
            ]

            started = time.monotonic()
            returncode: int | None = None
            timed_out = False
            stdout = ""
            stderr = ""
            try:
                completed = subprocess.run(
                    command,
                    input=prompt,
                    text=True,
                    capture_output=True,
                    env=env,
                    timeout=args.timeout,
                    check=False,
                )
                returncode = completed.returncode
                stdout = completed.stdout
                stderr = completed.stderr
            except subprocess.TimeoutExpired as exc:
                timed_out = True
                returncode = 124
                stdout = exc.stdout or ""
                stderr = (exc.stderr or "") + f"\n[TIMEOUT after {args.timeout} seconds]\n"
                if isinstance(stdout, bytes):
                    stdout = stdout.decode("utf-8", errors="replace")
                if isinstance(stderr, bytes):
                    stderr = stderr.decode("utf-8", errors="replace")

            duration = round(time.monotonic() - started, 3)
            raw_path.write_text(stdout, encoding="utf-8")
            err_path.write_text(stderr, encoding="utf-8")
            final_text = final_path.read_text(encoding="utf-8") if final_path.exists() else ""
            record = {
                "id": item["id"],
                "scene": item["scene"],
                "condition": condition,
                "returncode": returncode,
                "timed_out": timed_out,
                "duration_seconds": duration,
                "final_chars": len(final_text),
                "final_nonempty": bool(final_text.strip()),
                "raw_path": str(raw_path.relative_to(out)),
                "stderr_path": str(err_path.relative_to(out)),
                "final_path": str(final_path.relative_to(out)),
            }
            manifest.append(record)
            print(json.dumps(record, ensure_ascii=False), flush=True)

    (out / "run-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
