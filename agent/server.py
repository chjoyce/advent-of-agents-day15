import os
from fastapi import FastAPI, Header, HTTPException
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types
from pydantic import BaseModel
import uvicorn

from agent import root_agent

app = FastAPI(title="Memory Isolation & Regional Compliance Demo Agent")
session_service = InMemorySessionService()

runner = Runner(
    agent=root_agent,
    app_name="memory-isolation-demo-agent",
    session_service=session_service,
)


class QueryRequest(BaseModel):
    input: str
    session_id: str | None = None
    # Optional fallback fields for local testing when not behind an IAP/JWT proxy:
    user_id: str = "alice@bank.com"
    tenant_lob: str = "retail_banking"
    data_region: str = "us-central1"


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/query")
async def query(
    req: QueryRequest,
    # In production behind Identity-Aware Proxy (IAP), Apigee, or Agent Gateway,
    # these identity claims come from cryptographically verified headers/JWTs:
    x_verified_user_id: str | None = Header(default=None),
    x_verified_lob: str | None = Header(default=None),
    x_verified_region: str | None = Header(default=None),
):
    verified_user_id = x_verified_user_id or req.user_id
    verified_lob = x_verified_lob or req.tenant_lob
    verified_region = x_verified_region or req.data_region

    if verified_region not in ("us-central1", "europe-west1"):
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported data_region: {verified_region}",
        )

    session_id = req.session_id or f"sess-{verified_lob}-{verified_user_id}"
    session = await session_service.get_session(
        app_name="memory-isolation-demo-agent",
        user_id=verified_user_id,
        session_id=session_id,
    )
    if session is None:
        # Inject verified tenant_lob and data_region into server-controlled session state.
        # Tools read these values via `tool_context.state` and `tool_context.user_id`.
        session = await session_service.create_session(
            app_name="memory-isolation-demo-agent",
            user_id=verified_user_id,
            session_id=session_id,
            state={
                "tenant_lob": verified_lob,
                "data_region": verified_region,
            },
        )

    content = types.Content(
        role="user",
        parts=[types.Part.from_text(text=req.input)],
    )

    final_text = ""
    async for event in runner.run_async(
        user_id=verified_user_id,
        session_id=session.id,
        new_message=content,
    ):
        if event.is_final_response() and event.content and event.content.parts:
            final_text = "".join(
                part.text for part in event.content.parts if part.text
            )

    return {
        "output": final_text,
        "session_id": session.id,
        "enforced_context": {
            "user_id": verified_user_id,
            "tenant_lob": verified_lob,
            "data_region": verified_region,
        },
    }


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(app, host="0.0.0.0", port=port)
