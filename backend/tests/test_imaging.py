from __future__ import annotations

import io

import pytest
from PIL import Image

from app.imaging import ImageTooLarge, NotAnImage, normalise_image, sniff_format
from conftest import make_jpeg, make_png


def test_sniff_format():
    assert sniff_format(make_jpeg()) == "JPEG"
    assert sniff_format(make_png()) == "PNG"
    assert sniff_format(b"%PDF-1.4") is None
    assert sniff_format(b"") is None


def test_normalise_downscales_long_side(tmp_path):
    dest = tmp_path / "page.png"
    size = normalise_image(make_jpeg(5000, 2500), dest, max_side=3000)
    assert size == (3000, 1500)
    with Image.open(dest) as im:
        assert im.format == "PNG"
        assert im.mode == "RGB"
        assert im.size == (3000, 1500)


def test_normalise_keeps_small_images(tmp_path):
    dest = tmp_path / "page.png"
    assert normalise_image(make_png(640, 480), dest, max_side=3000) == (640, 480)


def test_normalise_applies_exif_rotation(tmp_path):
    image = Image.new("RGB", (400, 200), "white")
    exif = Image.Exif()
    exif[0x0112] = 6  # rotate 90° clockwise
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", exif=exif.tobytes())
    dest = tmp_path / "page.png"
    assert normalise_image(buffer.getvalue(), dest) == (200, 400)


def test_normalise_flattens_transparency_onto_white(tmp_path):
    dest = tmp_path / "page.png"
    normalise_image(make_png(50, 50, mode="RGBA"), dest)
    with Image.open(dest) as im:
        assert im.mode == "RGB"
        assert im.getpixel((10, 10)) == (255, 255, 255)


def test_normalise_rejects_non_images(tmp_path):
    with pytest.raises(NotAnImage):
        normalise_image(b"<svg xmlns='http://www.w3.org/2000/svg'/>", tmp_path / "x.png")
    with pytest.raises(NotAnImage):
        normalise_image(make_jpeg()[:200], tmp_path / "y.png")  # truncated file


def test_normalise_rejects_decompression_bombs(tmp_path, monkeypatch):
    monkeypatch.setattr(Image, "MAX_IMAGE_PIXELS", 10_000)
    with pytest.raises(ImageTooLarge):
        normalise_image(make_png(400, 400), tmp_path / "bomb.png")
