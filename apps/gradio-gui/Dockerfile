FROM ghcr.io/astral-sh/uv:python3.11-bookworm-slim

WORKDIR /app
ENV UV_HTTP_TIMEOUT=300

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY main.py .

EXPOSE 7860

ENV PATH="/app/.venv/bin:${PATH}"

CMD ["python", "main.py"]
