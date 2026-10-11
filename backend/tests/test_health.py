from app import __version__


def test_healthz(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["engine"] == "homr"
    assert body["version"] == __version__


def test_instruments_list(client):
    body = client.get("/v1/instruments").json()
    assert "cello" in body["instruments"]
    assert "double-bass" in body["instruments"]
    assert len(body["instruments"]) == 22
