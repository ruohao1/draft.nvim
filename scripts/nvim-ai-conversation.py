#!/usr/bin/env python3
"""One trusted editor/controller lifetime; ACP workers are created by explicit turns."""
import argparse
import importlib.util
import os
from pathlib import Path
import select
import sys


HERE = Path(__file__).resolve().parent


def helper(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


protocol = helper("nvim-ai-conversation-protocol")
review = helper("nvim-ai-review")


def configuration(path):
    value = protocol.decode_json(review._private_bytes(path, protocol.MAX_COMMAND))
    if (not isinstance(value, dict) or not {"opencode", "bwrap", "model"} <= value.keys()
            or set(value) - {"opencode", "bwrap", "model", "auth_file", "provider"}
            or not protocol.model(value["model"])
            or not all(protocol.path(value[key], True) for key in ("opencode", "bwrap"))
            or ("auth_file" in value and not protocol.path(value["auth_file"], True))
            or ("provider" in value and (not isinstance(value["provider"], dict)
                 or set(value["provider"]) != {value["model"].split("/", 1)[0]}))):
        raise protocol.Refused("Invalid trusted controller configuration")
    return value


class Controller:
    def __init__(self, config, pipe):
        self.config, self.pipe = config, pipe
        self.binding = protocol.Binding()

    def run(self):
        closing = False
        while True:
            frames = self.pipe.read_ready()
            for frame in frames:
                if closing:
                    raise protocol.Refused("Command follows controller close")
                if not self.binding.accept(frame):
                    continue
                command = frame["command"]
                if command["kind"] != "close":
                    raise protocol.Refused("Conversation execution is not available")
                event = {key: command[key] for key in protocol.IDENTITIES}
                event.update(kind="closed", sequence=1, stopped=True, cleaned=True, tokens_retired=True)
                self.pipe.enqueue(frame["serial"], event)
                closing = True
            self.pipe.flush_ready()
            if closing and not self.pipe.writing:
                return 0
            if self.pipe.eof and not closing:
                return 0
            select.select([] if self.pipe.eof else [self.pipe.input],
                          [self.pipe.output] if self.pipe.writing else [], [], .05)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        config = configuration(args.config)
        return Controller(config, protocol.EditorPipe(sys.stdin.fileno(), sys.stdout.fileno())).run()
    except (OSError, ValueError, protocol.Refused):
        print("Draft conversation failed; explicit recovery required.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
