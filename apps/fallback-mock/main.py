from fastapi import FastAPI

app = FastAPI(title="fallback-mock")


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "fallback-mock"}


@app.post("/v1/chat/completions")
async def chat_completions() -> dict:
    return {
        "id": "chatcmpl-fallback-mock",
        "object": "chat.completion",
        "created": 0,
        "model": "fallback-mock",
        "choices": [
            {
                "index": 0,
                "finish_reason": "stop",
                "message": {
                    "role": "assistant",
                    "content": "Fallback response from mock endpoint.",
                },
            }
        ],
    }


@app.get("/v1/models")
async def models() -> dict:
    return {
        "object": "list",
        "data": [{"id": "fallback-mock", "object": "model", "owned_by": "platform"}],
    }
