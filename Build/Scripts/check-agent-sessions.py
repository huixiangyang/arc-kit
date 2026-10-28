#!/usr/bin/env python3
"""用真实 Codex 生成本地替身回合，调用 Arc Kit 的隔离备份/恢复验收入口。"""
import argparse
import http.server
import json
import os
from pathlib import Path
import select
import shutil
import sqlite3
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
REPLY = "Arc Kit native recovery fixture response."


class FixtureServer(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        item = {"id": "msg_backup_fixture", "type": "message", "status": "completed", "role": "assistant",
                "content": [{"type": "output_text", "text": REPLY, "annotations": []}]}
        response = {"id": "resp_backup_fixture", "object": "response", "status": "completed", "output": [item],
                    "usage": {"input_tokens": 10, "output_tokens": 8, "total_tokens": 18}}
        events = [
            ("response.created", {"response": {**response, "status": "in_progress", "output": []}}),
            ("response.output_item.added", {"output_index": 0, "item": {**item, "status": "in_progress", "content": []}}),
            ("response.content_part.added", {"item_id": item["id"], "output_index": 0, "content_index": 0,
                                            "part": {"type": "output_text", "text": "", "annotations": []}}),
            ("response.output_text.delta", {"item_id": item["id"], "output_index": 0, "content_index": 0, "delta": REPLY}),
            ("response.output_text.done", {"item_id": item["id"], "output_index": 0, "content_index": 0, "text": REPLY}),
            ("response.output_item.done", {"output_index": 0, "item": item}),
            ("response.completed", {"response": response}),
        ]
        data = "".join(f"event: {kind}\ndata: {json.dumps({'type': kind, **value})}\n\n" for kind, value in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


class Codex:
    def __init__(self, executable, home, project, port, log):
        self.sequence = 0
        self.buffer = b""
        self.process = subprocess.Popen(
            [str(executable), "app-server", "--stdio", "-c", 'model="gpt-6.1-sol"', "-c", 'model_provider="archive"',
             "-c", f'model_providers.archive={{name="Archive fixture",base_url="http://127.0.0.1:{port}/v1",wire_api="responses",requires_openai_auth=false}}',
             "-c", "analytics.enabled=false"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, cwd=project,
            env={"HOME": str(home), "CODEX_HOME": str(home), "TMPDIR": str(home), "PATH": "/usr/bin:/bin:/usr/local/bin"},
            bufsize=0,
        )
        hello = self.request("initialize", {"clientInfo": {"name": "arc-kit-backup-fixture", "version": "1"}, "capabilities": {"experimentalApi": True}})
        if "/0.163.0 " not in hello.get("userAgent", ""):
            self.close()
            raise RuntimeError("Native acceptance currently requires Codex CLI 0.163.0")

    def request(self, method, params):
        self.sequence += 1
        self.process.stdin.write((json.dumps({"id": self.sequence, "method": method, "params": params}) + "\n").encode())
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if b"\n" not in self.buffer:
                ready, _, _ = select.select([self.process.stdout], [], [], 1)
                if not ready:
                    continue
                data = os.read(self.process.stdout.fileno(), 1_048_576)
                if not data:
                    raise RuntimeError("Codex stopped before replying")
                self.buffer += data
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                message = json.loads(line)
                if message.get("id") == self.sequence:
                    if "error" in message:
                        raise RuntimeError(message["error"])
                    return message["result"]
        raise TimeoutError(method)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New isolated output directory")
    parser.add_argument("--codex", type=Path, default=shutil.which("codex"))
    parser.add_argument("--app", type=Path, default=ROOT / ".build/debug/ArcKitApp")
    args = parser.parse_args()
    if args.codex is None:
        parser.error("Choose the Codex CLI with --codex")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    home = output / "source-codex"
    project = output / "project"
    home.mkdir(mode=0o700)
    project.mkdir(mode=0o700)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureServer)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    threads = []
    try:
        with (output / "codex.log").open("w") as log:
            client = Codex(args.codex.resolve(), home, project, server.server_port, log)
            try:
                for mode in ["legacy", "paginated"]:
                    thread = client.request("thread/start", {"cwd": str(project), "historyMode": mode, "approvalPolicy": "never", "sandbox": "read-only"})["thread"]
                    client.request("turn/start", {"threadId": thread["id"], "input": [{"type": "text", "text": "Reply with the fixture response. Do not use tools."}]})
                    deadline = time.monotonic() + 20
                    while time.monotonic() < deadline:
                        rollout = Path(thread["path"])
                        # turn/start 受理早于首条日志落盘；只在完整元数据行可读后查询历史。
                        if not rollout.exists() or not rollout.open("rb").readline().endswith(b"\n"):
                            time.sleep(0.05)
                            continue
                        read = client.request("thread/read", {"threadId": thread["id"], "includeTurns": True})["thread"]
                        if read["turns"] and read["turns"][-1]["status"] == "completed":
                            break
                        time.sleep(0.1)
                    else:
                        raise TimeoutError("The local fixture turn did not finish")
                    client.request("thread/name/set", {"threadId": thread["id"], "name": "Arc Kit " + mode + " recovery"})
                    if mode == "legacy":
                        client.request("thread/archive", {"threadId": thread["id"]})
                    threads.append(thread)
            finally:
                client.close()
    finally:
        server.shutdown()
        server.server_close()
    # 合成一个子会话数据样本，不启动或委派任何子 Agent。
    original = Path(threads[1]["path"])
    child_id = str(uuid.uuid4())
    rows = [json.loads(line) for line in original.read_text().splitlines()]
    def replace_thread_ids(value):
        if isinstance(value, dict):
            return {key: child_id if key == "thread_id" and item == threads[1]["id"] else replace_thread_ids(item) for key, item in value.items()}
        if isinstance(value, list):
            return [replace_thread_ids(item) for item in value]
        return value
    rows = replace_thread_ids(rows)
    rows[0]["payload"].update({"id": child_id, "session_id": threads[0]["id"],
        "source": {"subagent": {"thread_spawn": {"parent_thread_id": threads[0]["id"], "depth": 1}}}})
    child = original.with_name(original.name.replace(threads[1]["id"], child_id))
    child.write_text("".join(json.dumps(row) + "\n" for row in rows))
    byte_offsets = {0: 0}
    old_offset = new_offset = 0
    for old_line, new_line in zip(original.read_bytes().splitlines(keepends=True), child.read_bytes().splitlines(keepends=True)):
        old_offset += len(old_line)
        new_offset += len(new_line)
        byte_offsets[old_offset] = new_offset
    with sqlite3.connect(home / "state_5.sqlite") as database:
        database.execute("INSERT INTO thread_spawn_edges(parent_thread_id,child_thread_id,status) VALUES (?,?,'completed')", (threads[0]["id"], child_id))
    # 子会话无法独立 resume，复制已完成原生回合的投影并调整所属 ID 与字节进度。
    with sqlite3.connect(home / "thread_history_1.sqlite") as history:
        for table in ["thread_turns", "thread_items", "thread_history_projection_state", "thread_realtime_items"]:
            columns = [row[1] for row in history.execute(f"PRAGMA table_info({table})")]
            rows = history.execute(f"SELECT * FROM {table} WHERE thread_id=?", (threads[1]["id"],)).fetchall()
            for row in rows:
                values = list(row)
                values[columns.index("thread_id")] = child_id
                for index, name in enumerate(columns):
                    if name.endswith("byte_offset") and values[index] is not None:
                        values[index] = byte_offsets[values[index]]
                history.execute(f"INSERT INTO {table} VALUES ({','.join('?' for _ in columns)})", values)
    subprocess.run([str(args.app.resolve()), "--agent-sessions-check", str(home), str(output / "recovery"), str(args.codex.resolve())], check=True)
    print(output / "recovery/acceptance.json")


if __name__ == "__main__":
    main()
