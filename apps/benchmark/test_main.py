from apps.benchmark.main import resolve_runtime_profile


def test_local_cpu_profile_caps_concurrency_and_tokens():
    config = resolve_runtime_profile(url="http://localhost:8000/v1/chat/completions", concurrency=4, max_tokens=128)
    assert config["concurrency"] == 2
    assert config["max_tokens"] == 32


def test_remote_profile_keeps_requested_values():
    config = resolve_runtime_profile(url="https://example.com/v1/chat/completions", concurrency=8, max_tokens=256)
    assert config["concurrency"] == 8
    assert config["max_tokens"] == 256
