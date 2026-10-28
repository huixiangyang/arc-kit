#!/usr/bin/env python3
"""经用户授权后运行临时自有状态项检查；独立监督进程只终止自己启动的子进程。"""
import argparse
from pathlib import Path
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="尚不存在的证据目录")
    parser.add_argument("--widths", action="store_true", help="对比分段占位的展开、收起和恢复")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output.exists():
        parser.error("输出目录已存在，请换一个新目录")
    executable = root / ".build/debug/ArcKitApp"
    if not executable.is_file():
        parser.error("请先执行 swift build --product ArcKitApp")
    process = subprocess.Popen(
        [str(executable), "--menu-bar-width-check" if args.widths else "--menu-bar-native-check", str(output)],
        cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    print(f"Native check PID={process.pid}; output={output}", flush=True)
    interrupted = False
    try:
        log, _ = process.communicate(timeout=40)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        interrupted = True
        process.terminate()
        try:
            log, _ = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            log, _ = process.communicate()
    print(log, end="")
    if output.is_dir():
        with (output / "supervisor.log").open("x") as handle:
            handle.write(f"pid={process.pid} exit={process.returncode} interrupted={interrupted}\n{log}")
    return 124 if interrupted else process.returncode


if __name__ == "__main__":
    sys.exit(main())
