import logging
import os

try:
    import gradio as gr
    from openai import OpenAI
except ImportError as exc:  # pragma: no cover - user-friendly runtime guard
    raise SystemExit(
        "Gradio dependencies are not installed for this app. "
        "Run: cd apps/gradio-gui && uv sync"
    ) from exc

# Target Kong API Gateway or direct vLLM instance
API_BASE_URL = os.getenv("VLLM_API_BASE", "http://kong:8000/v1")
API_KEY = os.getenv("VLLM_API_KEY", "secret-api-key")
VERBOSE = os.getenv("GRADIO_VERBOSE", "false").lower() in {"1", "true", "yes", "on"}

logging.basicConfig(
    level=logging.DEBUG if VERBOSE else logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logging.getLogger("gradio").setLevel(logging.DEBUG if VERBOSE else logging.INFO)
logger = logging.getLogger("gradio-gui")

client = OpenAI(
    base_url=API_BASE_URL,
    api_key=API_KEY,
    default_headers={"apikey": API_KEY},
)


def build_messages(history):
    if not history:
        return []

    messages = []
    for item in history:
        if isinstance(item, dict):
            role = item.get("role")
            content = item.get("content")
            if role in {"user", "assistant"} and content not in (None, ""):
                messages.append({"role": role, "content": str(content)})
            continue

        if isinstance(item, (list, tuple)) and len(item) >= 2:
            user_msg, assistant_msg = item[0], item[1]
            if user_msg not in (None, ""):
                messages.append({"role": "user", "content": str(user_msg)})
            if assistant_msg not in (None, ""):
                messages.append({"role": "assistant", "content": str(assistant_msg)})

    return messages


def get_available_models():
    """Dynamically fetch served models from the OpenAI-compatible endpoint."""
    try:
        models = client.models.list()
        return [model.id for model in models.data]
    except Exception as e:
        logger.warning("Could not fetch models from %s: %s", API_BASE_URL, e)
        return ["default-model"]


def check_backend_ready(model_name=None):
    """Confirm that the OpenAI-compatible backend is responding and serving models."""
    try:
        available = get_available_models()
        if not available or available == ["default-model"]:
            return False, "Backend did not report any valid served models yet"

        if model_name and model_name not in available and model_name != "default-model":
            return False, f"Requested model '{model_name}' is not currently served. Available: {available}"

        return True, f"Ready ({', '.join(available[:3])}{'...' if len(available) > 3 else ''})"
    except Exception as e:
        logger.warning("Backend readiness check failed: %s", e)
        return False, f"Backend not ready yet: {e}"


def refresh_models_and_status():
    models = get_available_models()
    ready, status = check_backend_ready(models[0] if models else None)
    status_text = (
        "✅ Backend ready. " + status if ready else "⚠️ Backend warming up. " + status
    )
    return gr.update(
        choices=models,
        value=models[0] if models else "default-model",
    ), status_text


def predict(message, history, model_name, system_prompt, max_tokens, temperature):
    if message is None or str(message).strip() == "":
        yield "⚠️ Error: Please enter a message before sending."
        return

    ready, status = check_backend_ready(model_name)
    if not ready:
        logger.warning("Refusing to send prompt while backend is not ready: %s", status)
        yield f"⚠️ Error: {status}. Please wait for the model to finish warming up and retry."
        return

    history = history or []
    messages = build_messages(history)
    if system_prompt:
        messages.insert(0, {"role": "system", "content": system_prompt})

    messages.append({"role": "user", "content": str(message)})
    logger.debug(
        "Submitting chat completion: model=%s, history_items=%s, max_tokens=%s, temperature=%s",
        model_name,
        len(history),
        max_tokens,
        temperature,
    )

    try:
        response = client.chat.completions.create(
            model=model_name,
            messages=messages,
            max_tokens=max_tokens,
            temperature=temperature,
            stream=True,
        )

        partial_message = ""
        for chunk in response:
            choices = getattr(chunk, "choices", None) or []
            if not choices:
                continue

            choice = choices[0]
            delta = getattr(choice, "delta", None)
            content = getattr(delta, "content", None) if delta is not None else None
            if content:
                partial_message += str(content)
                yield partial_message
    except Exception as e:
        logger.exception("Chat completion failed")
        yield f"⚠️ Error communicating with vLLM Backend: {str(e)}"

available_models = get_available_models()
backend_ready, backend_status = check_backend_ready(available_models[0] if available_models else None)
logger.info(
    "Starting Gradio demo against %s with %d model choices (backend_ready=%s)",
    API_BASE_URL,
    len(available_models),
    backend_ready,
)

with gr.Blocks(title="vLLM Platform Demo") as demo:
    gr.Markdown("# 🚀 vLLM Inference Platform Demo")
    backend_status_box = gr.Markdown(
        "✅ Backend ready. " + backend_status if backend_ready
        else "⚠️ Backend warming up. " + backend_status
    )

    with gr.Row():
        with gr.Column(scale=1):
            model_dropdown = gr.Dropdown(
                choices=available_models,
                value=available_models[0] if available_models else "default-model",
                label="Served Model",
                interactive=True,
            )
            refresh_btn = gr.Button("🔄 Refresh Models")

            system_prompt_input = gr.Textbox(
                value="You are a helpful AI assistant.",
                label="System Prompt",
                lines=2,
            )
            max_tokens_slider = gr.Slider(
                minimum=128,
                maximum=1024,
                value=512,
                step=128,
                label="Max Tokens",
                info="Backend context limit is 1024 tokens. Requests exceeding this will fail on Kubernetes deployments.",
            )
            temperature_slider = gr.Slider(
                minimum=0.0, maximum=1.0, value=0.7, step=0.05, label="Temperature"
            )

            def update_models_and_status():
                return refresh_models_and_status()

            refresh_btn.click(
                fn=update_models_and_status,
                outputs=[model_dropdown, backend_status_box],
            )

        with gr.Column(scale=3):
            gr.ChatInterface(
                fn=predict,
                additional_inputs=[
                    model_dropdown,
                    system_prompt_input,
                    max_tokens_slider,
                    temperature_slider,
                ],
            )

if __name__ == "__main__":
    demo.queue().launch(
        server_name="0.0.0.0",
        server_port=7860,
        debug=VERBOSE,
        show_error=True,
        quiet=not VERBOSE,
    )
