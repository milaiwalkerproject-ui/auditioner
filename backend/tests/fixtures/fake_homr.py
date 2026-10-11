#!/usr/bin/env python3
"""A stand-in for the homr command line, used by the tests (HOMR_CMD="python3 fake_homr.py").

It behaves like homr 0.7.0 as far as the adapter can see: it takes exactly the
options the real one takes (an unknown flag is an argparse error, exit 2, like the
real tool), writes `<image stem>.musicxml` next to the image (plus a `_teaser.png`),
and exits 0. Behaviour is steered with environment variables:

  FAKE_HOMR_MODE    ok (default) | silent (exit 0, no output) | crash (exit 1) |
                    hang (sleep 60 s) | hang-child (start a child that sleeps 60 s
                    and wait for it — for the process-group kill test) |
                    title (print the OCR'd title like homr does, then crash) |
                    garbage (writes text that is not XML) | empty (writes an empty file)
  FAKE_HOMR_XML     path of the MusicXML file to copy (default: homr_sample.musicxml here)
  FAKE_HOMR_RECORD  if set, a JSON file is written there describing what the script saw
                    (input directory, the files in it, the cwd, argv, the environment
                    variable names) so tests can check the temp directory was deleted
                    afterwards and what the engine was given
  FAKE_HOMR_CHILD_PID_FILE  hang-child mode writes the child's pid here
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def main() -> None:
    parser = argparse.ArgumentParser(prog="homer")
    parser.add_argument("image", type=str, nargs="?")
    parser.add_argument("--init", action="store_true")
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--cache", action="store_true")
    parser.add_argument("--output-large-page", action="store_true")
    parser.add_argument("--output-metronome", type=int)
    parser.add_argument("--output-tempo", type=int)
    parser.add_argument("--write-staff-positions", action="store_true")
    parser.add_argument("--read-staff-positions", action="store_true")
    parser.add_argument("--coreml-encoder", action="store_true")
    args = parser.parse_args()  # strict, like homr: unknown flags exit 2

    if args.init:
        print("Init finished", file=sys.stderr)
        return
    if not args.image:
        print("No image provided", file=sys.stderr)
        sys.exit(1)

    image = args.image
    directory = os.path.dirname(os.path.abspath(image))
    record = os.environ.get("FAKE_HOMR_RECORD")
    if record:
        with open(record, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "image": os.path.abspath(image),
                    "dir": directory,
                    "files": sorted(os.listdir(directory)),
                    "cwd": os.getcwd(),
                    "argv": sys.argv[1:],
                    "env_names": sorted(os.environ),
                },
                fh,
            )

    mode = os.environ.get("FAKE_HOMR_MODE", "ok")
    print(f"Processing {image}", file=sys.stderr)
    if mode == "hang":
        time.sleep(60)
        return
    if mode == "hang-child":
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        pid_file = os.environ.get("FAKE_HOMR_CHILD_PID_FILE")
        if pid_file:
            with open(pid_file, "w", encoding="utf-8") as fh:
                fh.write(str(child.pid))
        child.wait()
        return
    if mode == "crash":
        print("Traceback (most recent call last): boom", file=sys.stderr)
        sys.exit(1)
    if mode == "title":
        print("Found title: Secret Sonata For Nobody", file=sys.stderr)
        print("Traceback (most recent call last): boom after title", file=sys.stderr)
        sys.exit(1)
    if mode == "silent":
        print("An error occurred while processing the image: No staffs found", file=sys.stderr)
        return

    output = os.path.splitext(image)[0] + ".musicxml"
    teaser = os.path.splitext(image)[0] + "_teaser.png"
    with open(teaser, "wb") as fh:
        fh.write(b"\x89PNG not really")
    if mode == "garbage":
        with open(output, "w", encoding="utf-8") as fh:
            fh.write("this is not xml <<<")
        return
    if mode == "empty":
        open(output, "w", encoding="utf-8").close()
        return
    source = os.environ.get("FAKE_HOMR_XML") or os.path.join(HERE, "homr_sample.musicxml")
    shutil.copyfile(source, output)
    print(f"Result was written to {output}", file=sys.stderr)


if __name__ == "__main__":
    main()
