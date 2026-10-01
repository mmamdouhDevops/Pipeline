from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)


def test_health():
    assert client.get("/health").json() == {"status": "Healthy"}


def test_describe():
    r = client.post("/v1/describe", json={"image_url": "https://x/y.png"})
    assert r.status_code == 200 and "y.png" in r.json()["text"]
