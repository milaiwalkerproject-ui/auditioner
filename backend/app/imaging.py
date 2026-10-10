"""Turn whatever the phone sent into a plain RGB image homr can read.

EXIF orientation is applied, transparency is flattened onto white, the longest side
is capped (homr resizes internally anyway, and smaller files are faster to write and
read) and the result is written as PNG next to where homr will put its output.

Decompression bombs: a tiny PNG can claim to be 30 000 × 30 000 px and would take
2.7 GB of RAM to decode. `probe` reads only the header and refuses anything over
MAX_PIXELS before a single pixel is decoded; Pillow's own MAX_IMAGE_PIXELS is set to
the same number as a backstop (it refuses outright at twice that).
"""

from __future__ import annotations

import io
import warnings
from pathlib import Path

from PIL import Image, ImageOps, UnidentifiedImageError

# Pillow formats we accept. Anything else (PDF, HEIC without a plugin, text…) is a 415.
ALLOWED_FORMATS = frozenset({"JPEG", "PNG", "WEBP", "TIFF", "BMP"})

# 50 megapixels: a 48 MP phone photo passes, a page scanned at 600 dpi (~35 MP) passes,
# a decompression bomb does not. A 50 MP RGB image is ~150 MB decoded.
MAX_PIXELS = 50_000_000
Image.MAX_IMAGE_PIXELS = MAX_PIXELS


class NotAnImage(Exception):
    """The upload could not be decoded as a supported picture."""


class ImageTooLarge(Exception):
    """The picture has far too many pixels to be a photo of a page (decompression bomb)."""


def _open(data: bytes) -> Image.Image:
    """Image.open with its failure modes mapped to ours. Reads the header only."""
    try:
        with warnings.catch_warnings():
            # `probe` rejects everything over MAX_PIXELS itself; Pillow's warning
            # for the 1–2× band would only add noise to the log.
            warnings.simplefilter("ignore", Image.DecompressionBombWarning)
            return Image.open(io.BytesIO(data))
    except Image.DecompressionBombError as exc:
        raise ImageTooLarge(str(exc)) from exc
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        raise NotAnImage(str(exc)) from exc


def probe(data: bytes) -> tuple[str, tuple[int, int]]:
    """(format, (width, height)) from the file header, without decoding pixels.

    Raises NotAnImage for anything that is not one of ALLOWED_FORMATS and
    ImageTooLarge when the declared size is over MAX_PIXELS.
    """
    if not data:
        raise NotAnImage("empty upload")
    with _open(data) as im:
        fmt, (width, height) = im.format, im.size
    if fmt not in ALLOWED_FORMATS:
        raise NotAnImage(f"unsupported format {fmt!r}")
    if width * height > MAX_PIXELS:
        raise ImageTooLarge(f"{width}x{height} px is over the {MAX_PIXELS} px limit")
    return fmt, (width, height)


def sniff_format(data: bytes) -> str | None:
    """Pillow's format name for the bytes, or None if it is not a known image.
    (Oversized images still raise ImageTooLarge.)"""
    try:
        with _open(data) as im:
            return im.format
    except NotAnImage:
        return None


def normalise_image(data: bytes, dest: Path, max_side: int = 3000) -> tuple[int, int]:
    """Decode `data`, straighten/flatten/downscale it and save it to `dest` as PNG.

    Returns the saved (width, height). Raises NotAnImage or ImageTooLarge.
    """
    probe(data)
    try:
        with _open(data) as opened:
            opened.load()
            im = ImageOps.exif_transpose(opened) or opened
            im = _flatten(im)
            width, height = im.size
            longest = max(width, height)
            if longest > max_side:
                scale = max_side / float(longest)
                new_size = (max(1, round(width * scale)), max(1, round(height * scale)))
                im = im.resize(new_size, Image.Resampling.LANCZOS)
            im.save(dest, format="PNG", compress_level=1)
            return im.size
    except Image.DecompressionBombError as exc:
        raise ImageTooLarge(str(exc)) from exc
    except (NotAnImage, ImageTooLarge):
        raise
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        raise NotAnImage(str(exc)) from exc


def _flatten(im: Image.Image) -> Image.Image:
    """RGB, with any transparency composited onto white (a page is white)."""
    if im.mode == "RGB":
        return im
    if im.mode in ("RGBA", "LA") or (im.mode == "P" and "transparency" in im.info):
        rgba = im.convert("RGBA")
        background = Image.new("RGB", rgba.size, (255, 255, 255))
        background.paste(rgba, mask=rgba.getchannel("A"))
        return background
    return im.convert("RGB")
