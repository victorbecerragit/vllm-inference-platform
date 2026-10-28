# Documentation Assets

Place documentation images in this folder.

For the README demo screenshot, use this exact filename:

- `gradio-vllm-demo.png`

That file is referenced by the root README at:

- `docs/assets/gradio-vllm-demo.png`

For the architecture diagram, use these exact filenames:

- `architecture-diagram.png` — rendered image embedded in the root README
- `architecture-diagram.svg` — editable vector source (edit this, then re-export the PNG)

They are referenced by the root README at:

- `docs/assets/architecture-diagram.png`

Keep the diagram wide (roughly 16:9) and at least 1400 px across so it stays legible on GitHub.
The PNG is exported at 2x (3200x1800) from a 1600x900 viewBox for crisp rendering on HiDPI displays.

Both files are generated from the same source layout; keep them in sync when editing. The current
diagram shows the LiteLLM cache hop, `fallback-mock` failover, Kong/vLLM scrape targets, the
`vllm:num_requests_waiting` KEDA trigger, and the HPA guardrail.