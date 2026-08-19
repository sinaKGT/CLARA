r"""Download every model the pipeline needs, up front, into the kit's models/ folder.

Run by install.ps1 with the kit's venv Python. HF_HOME / TORCH_HOME / NLTK_DATA are
already pointed at models\ by env.ps1, so nothing lands in your user profile.

Doing this now means the first conversation starts in seconds instead of stalling
for ten minutes behind a download.
"""

from __future__ import annotations

import argparse
import sys
import time

TTS_REPO = "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"
STT_REPO = "nvidia/parakeet-tdt-0.6b-v3"
STT_FILE = "parakeet-tdt-0.6b-v3.nemo"       # nano-parakeet loads the .nemo bundle
TURN_REPO = "pipecat-ai/smart-turn-v3"
TURN_FILE = "smart-turn-v3.2-cpu.onnx"

results: list[tuple[str, bool, str]] = []


def step(label: str):
    def deco(fn):
        def wrapped(*a, **kw):
            print(f"\n--- {label} ---", flush=True)
            t0 = time.time()
            try:
                fn(*a, **kw)
            except Exception as exc:  # noqa: BLE001 - report, never abort the batch
                print(f"    FAILED: {type(exc).__name__}: {exc}", flush=True)
                results.append((label, False, str(exc)[:160]))
            else:
                results.append((label, True, f"{time.time() - t0:.0f}s"))
        return wrapped
    return deco


@step("Gemma 4 E4B (LLM, GGUF)")
def fetch_gemma(repo: str, quant: str) -> None:
    from huggingface_hub import hf_hub_download

    name = f"gemma-4-E4B-it-{quant}.gguf"
    path = hf_hub_download(repo_id=repo, filename=name)
    print(f"    {path}", flush=True)


@step("Qwen3-TTS (speech output)")
def fetch_tts() -> None:
    from huggingface_hub import snapshot_download

    path = snapshot_download(
        repo_id=TTS_REPO,
        allow_patterns=["*.json", "*.txt", "*.safetensors", "speech_tokenizer/*"],
    )
    print(f"    {path}", flush=True)


@step("Parakeet TDT (speech recognition)")
def fetch_stt() -> None:
    from huggingface_hub import hf_hub_download

    path = hf_hub_download(repo_id=STT_REPO, filename=STT_FILE)
    print(f"    {path}", flush=True)


@step("Smart Turn v3.2 (end-of-turn detection)")
def fetch_smart_turn() -> None:
    from huggingface_hub import hf_hub_download

    path = hf_hub_download(repo_id=TURN_REPO, filename=TURN_FILE)
    print(f"    {path}", flush=True)


@step("Silero VAD v5 (voice activity)")
def fetch_vad() -> None:
    import torch

    torch.hub.load("snakers4/silero-vad", "silero_vad", trust_repo=True, skip_validation=True)
    print("    cached under models/torch/hub", flush=True)


@step("NLTK tokenizer data")
def fetch_nltk() -> None:
    import nltk

    for pkg in ("punkt_tab", "averaged_perceptron_tagger_eng"):
        nltk.download(pkg, quiet=True)
    print("    punkt_tab, averaged_perceptron_tagger_eng", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser(description="Pre-download speech-to-speech models.")
    ap.add_argument("--gemma-repo", default="ggml-org/gemma-4-E4B-it-GGUF")
    ap.add_argument("--quant", default="Q4_0", choices=["Q4_0", "Q8_0", "BF16"])
    ap.add_argument("--skip-llm", action="store_true", help="Skip the Gemma GGUF download.")
    args = ap.parse_args()

    print("Downloading models. Total is roughly 12 GB; resumable if interrupted.", flush=True)

    if not args.skip_llm:
        fetch_gemma(args.gemma_repo, args.quant)
    fetch_stt()
    fetch_tts()
    fetch_smart_turn()
    fetch_vad()
    fetch_nltk()

    print("\n=== summary ===", flush=True)
    failed = 0
    for label, ok, detail in results:
        mark = "ok  " if ok else "FAIL"
        print(f"  [{mark}] {label}  ({detail})", flush=True)
        if not ok:
            failed += 1

    if failed:
        print(f"\n{failed} download(s) failed. They will be retried automatically on first run.", flush=True)
        return 1
    print("\nAll models cached.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
