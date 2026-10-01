"""Minimal VLM service skeleton – replace `describe` with your model call."""
import os
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="vlm-service", version=os.getenv("APP_VERSION", "dev"))


class DescribeRequest(BaseModel):
    image_url: str
    prompt: str = "Describe the image."


class DescribeResponse(BaseModel):
    text: str
    model: str


@app.get("/health")
def health() -> dict:
    return {"status": "Healthy"}


@app.post("/v1/describe", response_model=DescribeResponse)
def describe(req: DescribeRequest) -> DescribeResponse:
    model = os.getenv("VLM_MODEL", "stub")
    return DescribeResponse(text=f"[{model}] {req.prompt} ({req.image_url})", model=model)
