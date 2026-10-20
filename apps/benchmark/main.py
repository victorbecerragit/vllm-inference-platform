#!/usr/bin/env python3
"""Async Streaming LLM Benchmark CLI Tool.

Measures Time-To-First-Token (TTFT), Inter-Token Latency (ITL), and
throughput across concurrent Server-Sent Events (SSE) chat completion requests.
"""

import argparse
import asyncio
import json
import os
import statistics
import sys
import time
from typing import Any, Dict, List, Optional

import httpx
from pydantic import BaseModel, Field


# ------------------------------------------------------------------------------
# Pydantic v2 Models
# ------------------------------------------------------------------------------
class ChatMessage(BaseModel):
    role: str = "user"
    content: str


class ChatCompletionPayload(BaseModel):
    model: str
    messages: List[ChatMessage]
    stream: bool = True
    max_tokens: int = Field(default=128, ge=1)
    temperature: float = Field(default=0.7, ge=0.0, le=2.0)


class RequestMetrics(BaseModel):
    request_id: int
    status_code: int
    success: bool
    prompt_tokens: int = 0
    completion_tokens: int = 0
    ttft_ms: float = 0.0
    avg_itl_ms: float = 0.0
    p95_itl_ms: float = 0.0
    total_duration_s: float = 0.0
    tokens_per_sec: float = 0.0
    cache_hit: Optional[bool] = None
    error: Optional[str] = None


class BenchmarkSummary(BaseModel):
    total_requests: int
    successful_requests: int
    failed_requests: int
    concurrency: int
    total_wall_time_s: float
    total_tokens_generated: int
    aggregate_tokens_per_sec: float
    avg_ttft_ms: float
    median_ttft_ms: float
    p95_ttft_ms: float
    p99_ttft_ms: float
    avg_itl_ms: float
    median_itl_ms: float
    p95_itl_ms: float
    p99_itl_ms: float


# ------------------------------------------------------------------------------
# Statistical Helpers
# ------------------------------------------------------------------------------
def calculate_percentile(data: List[float], percentile: float) -> float:
    """Calculate the p-th percentile of a list of floats."""
    if not data:
        return 0.0
    if len(data) == 1:
        return round(data[0], 2)
    sorted_data = sorted(data)
    k = (len(sorted_data) - 1) * (percentile / 100.0)
    f = int(k)
    c = f + 1
    if c >= len(sorted_data):
        return round(sorted_data[-1], 2)
    d0 = sorted_data[f] * (c - k)
    d1 = sorted_data[c] * (k - f)
    return round(d0 + d1, 2)


# ------------------------------------------------------------------------------
# Streaming Benchmark Worker
# ------------------------------------------------------------------------------
async def execute_streaming_request(
    client: httpx.AsyncClient,
    request_id: int,
    url: str,
    payload: ChatCompletionPayload,
    headers: Dict[str, str],
    semaphore: asyncio.Semaphore,
) -> RequestMetrics:
    """Send an async streaming chat completion request and measure latencies."""
    async with semaphore:
        t_dispatch = time.perf_counter()
        t_first_token: Optional[float] = None
        token_timestamps: List[float] = []
        tokens_received = 0
        error_msg: Optional[str] = None
        status_code = 0

        try:
            async with client.stream(
                "POST",
                url,
                json=payload.model_dump(),
                headers=headers,
            ) as response:
                status_code = response.status_code

                if response.status_code != 200:
                    body = await response.aread()
                    error_msg = f"HTTP {response.status_code}: {body.decode(errors='replace')[:200]}"
                    t_end = time.perf_counter()
                    return RequestMetrics(
                        request_id=request_id,
                        status_code=status_code,
                        success=False,
                        total_duration_s=round(t_end - t_dispatch, 4),
                        error=error_msg,
                    )

                cache_status = (
                    response.headers.get("x-cache-status")
                    or response.headers.get("x-kong-ai-cache-status")
                    or response.headers.get("x-litellm-cache")
                    or response.headers.get("x-litellm-cache-status")
                )
                cache_key = response.headers.get("x-litellm-cache-key")
                is_cache_hit = None
                if cache_status:
                    is_cache_hit = cache_status.lower() in (
                        "hit",
                        "cached",
                        "true",
                        "1",
                    )
                elif cache_key:
                    # LiteLLM documents x-litellm-cache-key on cached responses.
                    is_cache_hit = True
                elif "x-litellm-semantic-similarity" in response.headers:
                    is_cache_hit = True

                async for raw_line in response.aiter_lines():
                    line = raw_line.strip()
                    if not line or not line.startswith("data:"):
                        continue

                    data_str = line[5:].strip()
                    if data_str == "[DONE]":
                        break

                    now = time.perf_counter()
                    if t_first_token is None:
                        t_first_token = now

                    token_timestamps.append(now)

                    # Extract token delta if valid JSON
                    try:
                        chunk = json.loads(data_str)
                        choices = chunk.get("choices", [])
                        if choices:
                            delta = choices[0].get("delta", {})
                            if delta.get("content"):
                                tokens_received += 1
                    except json.JSONDecodeError:
                        tokens_received += 1

            t_end = time.perf_counter()
            total_duration_s = t_end - t_dispatch

            # Handle edge case where no SSE chunks were received
            if t_first_token is None:
                ttft_ms = round(total_duration_s * 1000.0, 2)
            else:
                ttft_ms = round((t_first_token - t_dispatch) * 1000.0, 2)

            # Compute Inter-Token Latencies (ITL)
            itls: List[float] = []
            for i in range(1, len(token_timestamps)):
                delta_ms = (token_timestamps[i] - token_timestamps[i - 1]) * 1000.0
                itls.append(delta_ms)

            avg_itl_ms = round(statistics.mean(itls), 2) if itls else 0.0
            p95_itl_ms = calculate_percentile(itls, 95) if itls else 0.0

            # Estimate token count if not parsed from JSON
            token_count = max(tokens_received, len(token_timestamps))
            throughput = (
                round(token_count / total_duration_s, 2)
                if total_duration_s > 0
                else 0.0
            )

            return RequestMetrics(
                request_id=request_id,
                status_code=status_code,
                success=True,
                completion_tokens=token_count,
                ttft_ms=ttft_ms,
                avg_itl_ms=avg_itl_ms,
                p95_itl_ms=p95_itl_ms,
                total_duration_s=round(total_duration_s, 4),
                tokens_per_sec=throughput,
                cache_hit=is_cache_hit,
            )

        except Exception as exc:  # pylint: disable=broad-except
            t_end = time.perf_counter()
            return RequestMetrics(
                request_id=request_id,
                status_code=status_code,
                success=False,
                total_duration_s=round(t_end - t_dispatch, 4),
                error=str(exc),
            )


# ------------------------------------------------------------------------------
# Orchestrator & Aggregator
# ------------------------------------------------------------------------------
async def run_benchmark(
    url: str,
    model: str,
    prompt: str,
    total_requests: int,
    concurrency: int,
    max_tokens: int,
    api_key: Optional[str],
    timeout: float,
) -> tuple[List[RequestMetrics], BenchmarkSummary]:
    """Execute the concurrent load test and compile statistical aggregations."""
    semaphore = asyncio.Semaphore(concurrency)
    headers = {
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }
    if api_key:
        headers["apikey"] = api_key
        headers["Authorization"] = f"Bearer {api_key}"

    payload = ChatCompletionPayload(
        model=model,
        messages=[ChatMessage(role="user", content=prompt)],
        stream=True,
        max_tokens=max_tokens,
    )

    timeout_cfg = httpx.Timeout(timeout=timeout, connect=10.0)
    limits_cfg = httpx.Limits(
        max_connections=concurrency * 2,
        max_keepalive_connections=concurrency,
    )

    t_wall_start = time.perf_counter()

    async with httpx.AsyncClient(
        timeout=timeout_cfg, limits=limits_cfg
    ) as client:
        tasks = [
            execute_streaming_request(
                client=client,
                request_id=idx + 1,
                url=url,
                payload=payload,
                headers=headers,
                semaphore=semaphore,
            )
            for idx in range(total_requests)
        ]
        results = await asyncio.gather(*tasks)

    t_wall_end = time.perf_counter()
    wall_time_s = max(t_wall_end - t_wall_start, 0.0001)

    successful = [r for r in results if r.success]
    failed = [r for r in results if not r.success]

    ttfts = [r.ttft_ms for r in successful]
    itls = [r.avg_itl_ms for r in successful if r.avg_itl_ms > 0]
    total_tokens = sum(r.completion_tokens for r in successful)

    summary = BenchmarkSummary(
        total_requests=total_requests,
        successful_requests=len(successful),
        failed_requests=len(failed),
        concurrency=concurrency,
        total_wall_time_s=round(wall_time_s, 3),
        total_tokens_generated=total_tokens,
        aggregate_tokens_per_sec=round(total_tokens / wall_time_s, 2),
        avg_ttft_ms=round(statistics.mean(ttfts), 2) if ttfts else 0.0,
        median_ttft_ms=round(statistics.median(ttfts), 2) if ttfts else 0.0,
        p95_ttft_ms=calculate_percentile(ttfts, 95),
        p99_ttft_ms=calculate_percentile(ttfts, 99),
        avg_itl_ms=round(statistics.mean(itls), 2) if itls else 0.0,
        median_itl_ms=round(statistics.median(itls), 2) if itls else 0.0,
        p95_itl_ms=calculate_percentile(itls, 95),
        p99_itl_ms=calculate_percentile(itls, 99),
    )

    return results, summary


# ------------------------------------------------------------------------------
# Console Output & Formatting
# ------------------------------------------------------------------------------
def render_tables(
    results: List[RequestMetrics], summary: BenchmarkSummary
) -> None:
    """Print results using tabulate or clean formatted plain text."""
    try:
        from tabulate import tabulate

        has_tabulate = True
    except ImportError:
        has_tabulate = False

    has_cache_info = any(r.cache_hit is not None for r in results)

    per_request_rows = []
    for r in results:
        status_str = "SUCCESS" if r.success else f"FAILED ({r.status_code})"
        row = [
            r.request_id,
            status_str,
            r.completion_tokens,
            f"{r.ttft_ms:.1f}",
            f"{r.avg_itl_ms:.1f}",
            f"{r.p95_itl_ms:.1f}",
            f"{r.total_duration_s:.3f}",
            f"{r.tokens_per_sec:.1f}",
        ]
        if has_cache_info:
            cache_str = "HIT" if r.cache_hit else ("MISS" if r.cache_hit is False else "-")
            row.append(cache_str)
        per_request_rows.append(row)

    per_request_headers = [
        "Req #",
        "Status",
        "Tokens",
        "TTFT (ms)",
        "Avg ITL (ms)",
        "P95 ITL (ms)",
        "Duration (s)",
        "Tok/sec",
    ]
    if has_cache_info:
        per_request_headers.append("Cache")

    summary_rows = [
        ["Total Requests", summary.total_requests],
        ["Successful Requests", summary.successful_requests],
        ["Failed Requests", summary.failed_requests],
        ["Concurrency", summary.concurrency],
        ["Total Wall Time", f"{summary.total_wall_time_s:.2f} s"],
        ["Total Tokens Generated", summary.total_tokens_generated],
        ["Aggregate Throughput", f"{summary.aggregate_tokens_per_sec:.2f} tokens/sec"],
        ["Average TTFT", f"{summary.avg_ttft_ms:.2f} ms"],
        ["Median (P50) TTFT", f"{summary.median_ttft_ms:.2f} ms"],
        ["P95 TTFT", f"{summary.p95_ttft_ms:.2f} ms"],
        ["P99 TTFT", f"{summary.p99_ttft_ms:.2f} ms"],
        ["Average ITL", f"{summary.avg_itl_ms:.2f} ms"],
        ["Median (P50) ITL", f"{summary.median_itl_ms:.2f} ms"],
        ["P95 ITL", f"{summary.p95_itl_ms:.2f} ms"],
        ["P99 ITL", f"{summary.p99_itl_ms:.2f} ms"],
    ]
    summary_headers = ["Metric", "Value"]

    print("\n" + "=" * 80)
    print("                    PER-REQUEST BENCHMARK METRICS")
    print("=" * 80)
    if has_tabulate:
        print(tabulate(per_request_rows, headers=per_request_headers, tablefmt="github"))
    else:
        fmt = "{:<6} {:<15} {:<8} {:<11} {:<14} {:<14} {:<13} {:<10}"
        print(fmt.format(*per_request_headers))
        print("-" * 80)
        for row in per_request_rows:
            print(fmt.format(*[str(c) for c in row]))

    print("\n" + "=" * 80)
    print("                       AGGREGATE BENCHMARK SUMMARY")
    print("=" * 80)
    if has_tabulate:
        print(tabulate(summary_rows, headers=summary_headers, tablefmt="github"))
    else:
        fmt = "{:<30} {:<30}"
        print(fmt.format(*summary_headers))
        print("-" * 60)
        for row in summary_rows:
            print(fmt.format(str(row[0]), str(row[1])))
    print("=" * 80 + "\n")


# ------------------------------------------------------------------------------
# Cache Benchmark Workflow
# ------------------------------------------------------------------------------
async def run_cache_benchmark(
    url: str,
    model: str,
    prompt: str,
    max_tokens: int,
    api_key: Optional[str],
    timeout: float,
) -> tuple[RequestMetrics, RequestMetrics]:
    """Execute sequential cold (uncached) and warm (cached) duplicate requests."""
    semaphore = asyncio.Semaphore(1)
    headers = {
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }
    if api_key:
        headers["apikey"] = api_key
        headers["Authorization"] = f"Bearer {api_key}"

    payload = ChatCompletionPayload(
        model=model,
        messages=[ChatMessage(role="user", content=prompt)],
        stream=True,
        max_tokens=max_tokens,
    )

    timeout_cfg = httpx.Timeout(timeout=timeout, connect=10.0)

    async with httpx.AsyncClient(timeout=timeout_cfg) as client:
        # First request: Populates cache (Cold / Uncached)
        uncached = await execute_streaming_request(
            client=client,
            request_id=1,
            url=url,
            payload=payload,
            headers=headers,
            semaphore=semaphore,
        )

        # Brief pause to ensure async cache writes persist
        await asyncio.sleep(0.5)

        # Second request: Duplicate prompt targeting cache (Warm / Cached)
        cached = await execute_streaming_request(
            client=client,
            request_id=2,
            url=url,
            payload=payload,
            headers=headers,
            semaphore=semaphore,
        )

    return uncached, cached


def render_cache_comparison(uncached: RequestMetrics, cached: RequestMetrics) -> None:
    """Print comparative table and summary between uncached and cached requests."""
    try:
        from tabulate import tabulate

        has_tabulate = True
    except ImportError:
        has_tabulate = False

    ttft_diff_ms = uncached.ttft_ms - cached.ttft_ms
    ttft_speedup = (
        f"{(uncached.ttft_ms / cached.ttft_ms):.1f}x"
        if cached.ttft_ms > 0
        else "N/A"
    )
    duration_speedup = (
        f"{(uncached.total_duration_s / cached.total_duration_s):.1f}x"
        if cached.total_duration_s > 0
        else "N/A"
    )

    comparison_rows = [
        [
            "1 (Cold / Uncached)",
            "SUCCESS" if uncached.success else f"FAILED ({uncached.status_code})",
            "MISS" if uncached.cache_hit is False else ("HIT" if uncached.cache_hit else "-"),
            f"{uncached.ttft_ms:.1f} ms",
            f"{uncached.total_duration_s:.3f} s",
            uncached.completion_tokens,
            f"{uncached.tokens_per_sec:.1f}",
        ],
        [
            "2 (Warm / Cached)",
            "SUCCESS" if cached.success else f"FAILED ({cached.status_code})",
            "HIT" if cached.cache_hit is True else ("MISS" if cached.cache_hit is False else "-"),
            f"{cached.ttft_ms:.1f} ms",
            f"{cached.total_duration_s:.3f} s",
            cached.completion_tokens,
            f"{cached.tokens_per_sec:.1f}",
        ],
    ]
    comparison_headers = [
        "Request",
        "Status",
        "Cache",
        "TTFT",
        "Total Duration",
        "Tokens",
        "Tok/sec",
    ]

    print("\n" + "=" * 80)
    print("                    SEMANTIC CACHE COMPARISON (COLD vs. WARM)")
    print("=" * 80)
    if has_tabulate:
        print(tabulate(comparison_rows, headers=comparison_headers, tablefmt="github"))
    else:
        fmt = "{:<22} {:<15} {:<8} {:<12} {:<16} {:<8} {:<10}"
        print(fmt.format(*comparison_headers))
        print("-" * 80)
        for row in comparison_rows:
            print(fmt.format(*[str(c) for c in row]))

    print("\n" + "=" * 80)
    print("                       CACHE PERFORMANCE GAINS")
    print("=" * 80)
    summary_rows = [
        ["Uncached TTFT", f"{uncached.ttft_ms:.2f} ms"],
        ["Cached TTFT", f"{cached.ttft_ms:.2f} ms"],
        ["TTFT Latency Reduction", f"{ttft_diff_ms:.2f} ms ({ttft_speedup} faster)"],
        ["Uncached Duration", f"{uncached.total_duration_s:.3f} s"],
        ["Cached Duration", f"{cached.total_duration_s:.3f} s"],
        ["Total Duration Reduction", f"{(uncached.total_duration_s - cached.total_duration_s):.3f} s ({duration_speedup} faster)"],
    ]
    if has_tabulate:
        print(tabulate(summary_rows, headers=["Metric", "Value"], tablefmt="github"))
    else:
        fmt = "{:<30} {:<30}"
        print(fmt.format("Metric", "Value"))
        print("-" * 60)
        for row in summary_rows:
            print(fmt.format(str(row[0]), str(row[1])))
    print("=" * 80 + "\n")


# ------------------------------------------------------------------------------
# Entrypoint & CLI Parsing
# ------------------------------------------------------------------------------
def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Benchmark vLLM Inference Platform streaming latencies (TTFT, ITL, Tok/s)."
    )
    parser.add_argument(
        "--url",
        type=str,
        default="http://localhost:8000/v1/chat/completions",
        help="Target chat completions URL (default: http://localhost:8000/v1/chat/completions)",
    )
    parser.add_argument(
        "--model",
        type=str,
        default=os.getenv("MODEL_NAME", "Qwen/Qwen2.5-0.5B-Instruct"),
        help="Model identifier (default: Qwen/Qwen2.5-0.5B-Instruct)",
    )
    parser.add_argument(
        "--requests",
        type=int,
        default=10,
        help="Total number of inference requests to issue (default: 10)",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=2,
        help="Maximum concurrent in-flight requests (default: 2)",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=128,
        help="Maximum tokens generated per request (default: 128)",
    )
    parser.add_argument(
        "--prompt",
        type=str,
        default="Explain Kubernetes autoscaling with KEDA and vLLM in two concise sentences.",
        help="User prompt content sent to the model",
    )
    parser.add_argument(
        "--api-key",
        type=str,
        default=os.getenv("API_KEY", "secret-api-key"),
        help="Kong Gateway API key for authentication (default: secret-api-key)",
    )
    parser.add_argument(
        "--cache-url",
        type=str,
        default=os.getenv("CACHE_TEST_URL"),
        help=(
            "Optional URL used only with --test-cache for deterministic cache validation "
            "(example: http://localhost:4000/v1/chat/completions)"
        ),
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=60.0,
        help="Request timeout in seconds (default: 60.0)",
    )
    parser.add_argument(
        "--test-cache",
        action="store_true",
        default=False,
        help="Test semantic caching by sending duplicate prompts to demonstrate cached vs uncached TTFT",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_arguments()

    if args.test_cache:
        test_url = args.cache_url or args.url
        print("\n[+] Starting Semantic Cache Verification Benchmark...")
        print(f"    Target URL:    {test_url}")
        print(f"    Target Model:  {args.model}")
        print(f"    Max Tokens:    {args.max_tokens}")
        print(f"    API Key:       {'Configured' if args.api_key else 'None'}")
        print(f"    Prompt:        \"{args.prompt}\"\n")

        uncached, cached = asyncio.run(
            run_cache_benchmark(
                url=test_url,
                model=args.model,
                prompt=args.prompt,
                max_tokens=args.max_tokens,
                api_key=args.api_key,
                timeout=args.timeout,
            )
        )

        render_cache_comparison(uncached, cached)

        if not uncached.success or not cached.success:
            print("[!] Warning: One or more cache test requests failed.")
            sys.exit(1)
        return

    print("\n[+] Starting vLLM Inference Platform Benchmark...")
    print(f"    Target URL:    {args.url}")
    print(f"    Target Model:  {args.model}")
    print(f"    Requests:      {args.requests}")
    print(f"    Concurrency:   {args.concurrency}")
    print(f"    Max Tokens:    {args.max_tokens}")
    print(f"    API Key:       {'Configured' if args.api_key else 'None'}\n")

    results, summary = asyncio.run(
        run_benchmark(
            url=args.url,
            model=args.model,
            prompt=args.prompt,
            total_requests=args.requests,
            concurrency=args.concurrency,
            max_tokens=args.max_tokens,
            api_key=args.api_key,
            timeout=args.timeout,
        )
    )

    render_tables(results, summary)

    if summary.failed_requests > 0:
        print(f"[!] Warning: {summary.failed_requests} requests failed during benchmarking.")
        sys.exit(1)


if __name__ == "__main__":
    main()
