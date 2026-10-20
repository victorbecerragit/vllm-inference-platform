import importlib.util
import sys
import types
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("main.py")


class FakeComponent:
    def __init__(self, *args, **kwargs):
        self.args = args
        self.kwargs = kwargs

    def click(self, *args, **kwargs):
        return self

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


class FakeContainer(FakeComponent):
    pass


class FakeBlocks(FakeComponent):

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def queue(self):
        return self

    def launch(self, *args, **kwargs):
        return None


class FakeModels:
    def list(self):
        return types.SimpleNamespace(data=[types.SimpleNamespace(id="demo-model")])


class FakeOpenAI:
    def __init__(self, *args, **kwargs):
        self.models = FakeModels()
        raw_response = types.SimpleNamespace(
            create=lambda **kwargs: types.SimpleNamespace(
                headers={},
                parse=lambda: iter([]),
            )
        )
        self.chat = types.SimpleNamespace(
            completions=types.SimpleNamespace(
                with_raw_response=raw_response
            )
        )


def load_module():
    fake_gradio = types.ModuleType("gradio")
    fake_gradio.Blocks = FakeBlocks
    fake_gradio.Markdown = FakeComponent
    fake_gradio.Row = FakeContainer
    fake_gradio.Column = FakeContainer
    fake_gradio.Dropdown = FakeComponent
    fake_gradio.Button = FakeComponent
    fake_gradio.Textbox = FakeComponent
    fake_gradio.Slider = FakeComponent
    fake_gradio.ChatInterface = FakeComponent
    fake_gradio.update = lambda **kwargs: kwargs

    fake_openai = types.ModuleType("openai")
    fake_openai.OpenAI = FakeOpenAI

    sys.modules["gradio"] = fake_gradio
    sys.modules["openai"] = fake_openai

    spec = importlib.util.spec_from_file_location("vllm_gradio_gui", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_build_messages_handles_chat_history():
    module = load_module()
    history = [["Hi", "Hello there"], {"role": "user", "content": "Again"}]

    messages = module.build_messages(history)

    assert messages == [
        {"role": "user", "content": "Hi"},
        {"role": "assistant", "content": "Hello there"},
        {"role": "user", "content": "Again"},
    ]


def test_build_messages_handles_none_history():
    module = load_module()

    assert module.build_messages(None) == []
    assert module.build_messages([]) == []


def test_backend_ready_check_uses_served_models():
    module = load_module()

    ready, status = module.check_backend_ready("demo-model")

    assert ready is True
    assert "demo-model" in status


def test_predict_ignores_stream_chunks_without_delta_content():
    module = load_module()

    class FakeChunk:
        def __init__(self, content):
            self.choices = [types.SimpleNamespace(delta=types.SimpleNamespace(content=content))]

    class FakeStreamResponse:
        headers = {}

        def parse(self):
            yield FakeChunk("Hello")
            yield FakeChunk(None)
            yield FakeChunk(" world")

    module.client.chat.completions.with_raw_response.create = lambda **kwargs: FakeStreamResponse()

    chunks = list(module.predict("hi", None, "demo-model", "", 64, 0.7))

    assert chunks[0:2] == ["Hello", "Hello world"]
    assert chunks[-1].startswith("Hello world\n\n<span")
    assert "cache n/a" in chunks[-1]


def test_cache_status_from_headers_hit_with_cache_key():
    module = load_module()

    status = module._cache_status_from_headers({"x-litellm-cache-key": "abc123"})

    assert status == "HIT"


def test_predict_appends_cache_status_when_header_present():
    module = load_module()

    class FakeChunk:
        def __init__(self, content):
            self.choices = [types.SimpleNamespace(delta=types.SimpleNamespace(content=content))]

    class FakeStreamResponse:
        headers = {"x-litellm-cache-key": "cache:key"}

        def parse(self):
            yield FakeChunk("Hello")
            yield FakeChunk(" world")

    module.client.chat.completions.with_raw_response.create = lambda **kwargs: FakeStreamResponse()

    chunks = list(module.predict("hi", None, "demo-model", "", 64, 0.7))

    assert chunks[0:2] == ["Hello", "Hello world"]
    assert chunks[-1].startswith("Hello world\n\n<span")
    assert "cache HIT" in chunks[-1]
