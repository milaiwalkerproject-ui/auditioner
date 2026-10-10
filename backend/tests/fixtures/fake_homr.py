#!/usr/bin/env python3
"""A stand-in for the homr command line, used by the tests (HOMR_CMD="python3 fake_homr.py").

It behaves like the real tool as far as the adapter can see: it is given an image
path, writes `<image stem>.musicxml` next to it (plus a `_teaser.png`, like homr), and
exits 0. Behaviour is steered with environment variables:

  FAKE_HOMR_MODE    ok (default) | silent (exit 0, no output — homr does this on a
                    recognition error) | crash (exit 1) | hang (sleep 60 s) |
                    garbage (writes text that is not XML) | empty (writes an empty file)
  FAKE_HOMR_XML     path of the MusicXML file to copy (default: homr_sample.musicxml here)
  FAKE_HOMR_RECORD  if set, a JSON file is written there describing what the script saw
                    (input directory, the files in it, the cwd) so tests can check the
                    temp directory was deleted afterwards
"""

import argparse
import json
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def main() -> None:
    parser = argparse.ArgumentParser(prog="fake-homr")
    parser.add_argument("image", nargs="*")
    parser.add_argument("--init", action="store_true")
    parser.add_argument("--no-title", action="store_true")
    args, _unknown = parser.parse_known_args()

    if args.init:
        print("Init finished", file=sys.stderr)
        return
    if not args.image:
        print("No image provided", file=sys.stderr)
        sys.exit(1)

    image = args.image[0]
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
                },
                fh,
            )

    mode = os.environ.get("FAKE_HOMR_MODE", "ok")
    print(f"Processing {image}", file=sys.stderr)
    if mode == "hang":
        time.sleep(60)
        return
    if mode == "crash":
        print("Traceback (most recent call last): boom", file=sys.stderr)
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
