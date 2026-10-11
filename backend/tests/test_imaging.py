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


# ------------------------------------------------------------ bombs & probing


def test_probe_reads_format_and_size():
    from conftest import fake_png
    from app.imaging import probe

    assert probe(make_jpeg(600, 400)) == ("JPEG", (600, 400))
    assert probe(fake_png(10, 10))[0] == "PNG"
    with pytest.raises(NotAnImage):
        probe(b"%PDF-1.4")
    with pytest.raises(NotAnImage):
        probe(b"")


def test_probe_refuses_too_many_pixels_without_decoding(tmp_path):
    """8000 x 8000 = 64 MP: over our limit, under Pillow's hard refusal (2x)."""
    from conftest import fake_png
    from app.imaging import MAX_PIXELS, probe

    assert Image.MAX_IMAGE_PIXELS == MAX_PIXELS
    bomb = fake_png(8000, 8000)
    assert len(bomb) < 200
    with pytest.raises(ImageTooLarge):
        probe(bomb)
    with pytest.raises(ImageTooLarge):
        normalise_image(bomb, tmp_path / "bomb.png")


def test_pillow_bomb_refusal_is_mapped(tmp_path):
    """30000 x 30000 px (900 MP): Pillow itself refuses at open; we map that too,
    also on the sniff path, so the endpoint never sees a bare DecompressionBombError."""
    from conftest import fake_png
    from app.imaging import probe

    bomb = fake_png(30000, 30000)
    with pytest.raises(ImageTooLarge):
        probe(bomb)
    with pytest.raises(ImageTooLarge):
        sniff_format(bomb)
    with pytest.raises(ImageTooLarge):
        normalise_image(bomb, tmp_path / "bomb.png")


def test_photo_sized_images_pass():
    """A 48 MP phone photo (8064 x 6048) is under the limit."""
    from conftest import fake_png
    from app.imaging import probe

    assert probe(fake_png(8064, 6048)) == ("PNG", (8064, 6048))
