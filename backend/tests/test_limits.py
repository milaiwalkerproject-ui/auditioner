import asyncio

import pytest

from app.limits import Busy, ConcurrencyGuard, DailyLimiter, clean_device_id


class FakeClock:
    def __init__(self) -> None:
        self.now = 1_000_000.0

    def __call__(self) -> float:
        return self.now


def test_sliding_window():
    clock = FakeClock()
    limiter = DailyLimiter(limit=3, clock=clock)
    assert limiter.remaining("a") == 3
    for _ in range(3):  # one scan per hour
        assert limiter.allow("a")
        clock.now += 3600
    assert not limiter.allow("a")
    assert limiter.remaining("a") == 0
    assert limiter.allow("b")  # other devices are independent

    clock.now += 20 * 3600  # 23 h after the first scan
    assert not limiter.allow("a")
    clock.now += 3600 + 1  # only the first scan is now older than 24 h
    assert limiter.allow("a")
    assert not limiter.allow("a")
    clock.now += 3600  # the second scan expires too
    assert limiter.allow("a")


def test_refund():
    limiter = DailyLimiter(limit=1)
    assert limiter.allow("a")
    assert not limiter.allow("a")
    limiter.refund("a")
    assert limiter.allow("a")
    limiter.refund("unknown")  # harmless


def test_zero_limit_blocks_everything():
    limiter = DailyLimiter(limit=0)
    assert not limiter.allow("a")


def test_sweep_drops_idle_devices():
    clock = FakeClock()
    limiter = DailyLimiter(limit=5, clock=clock)
    for i in range(600):
        limiter.allow(f"device-{i}")
    clock.now += 2 * 24 * 3600
    for _ in range(500):
        limiter.allow("fresh")
    assert "device-1" not in limiter._hits


def test_concurrency_guard_queue_and_busy():
    async def scenario() -> None:
        guard = ConcurrencyGuard(max_running=1, max_waiting=1)
        release = asyncio.Event()
        finished: list[str] = []

        async def job(name: str) -> None:
            async with guard.slot():
                finished.append(name)
                await release.wait()

        first = asyncio.create_task(job("first"))
        await asyncio.sleep(0.01)
        assert guard.running == 1
        second = asyncio.create_task(job("second"))
        await asyncio.sleep(0.01)
        assert guard.waiting == 1

        with pytest.raises(Busy):
            async with guard.slot():
                pass

        release.set()
        await asyncio.gather(first, second)
        assert finished == ["first", "second"]
        assert guard.running == 0 and guard.waiting == 0

        # after everything finished a new job gets straight in
        async with guard.slot():
            assert guard.running == 1

    asyncio.run(scenario())


def test_guard_releases_slot_on_error():
    async def scenario() -> None:
        guard = ConcurrencyGuard(max_running=1, max_waiting=0)
        with pytest.raises(RuntimeError):
            async with guard.slot():
                raise RuntimeError("engine blew up")
        async with guard.slot():
            assert guard.running == 1

    asyncio.run(scenario())


@pytest.mark.parametrize(
    "raw,expected",
    [
        (None, None),
        ("", None),
        ("   ", None),
        ("abc def", None),
        ("x" * 129, None),
        ("  6F0C9E2A-1B2C-4D5E-8F90-ABCDEF123456  ", "6F0C9E2A-1B2C-4D5E-8F90-ABCDEF123456"),
    ],
)
def test_clean_device_id(raw, expected):
    assert clean_device_id(raw) == expected
