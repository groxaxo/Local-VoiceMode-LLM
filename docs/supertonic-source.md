# Supertonic runtime repository access

Related: [issue #14](https://github.com/groxaxo/Local-VoiceMode-LLM/issues/14).

The Unix installer clones `groxaxo/supertonic-express-3` before installing the
Supertonic Python packages or downloading models. At the investigation on
2026-09-12, that runtime repository was private. GitHub returns `Repository not
found` to callers without access. This is a dependency distribution problem,
not evidence of a broken Mac, Python installation, MLX, or ONNX.

## What the preflight changes

Fresh installs check Git access before installing Python packages or changing
service definitions. An inaccessible source exits non-zero with guidance rather
than doing substantial setup before failing at the clone. Git terminal prompting
is disabled, but existing configured credentials can still be used. The probe's
raw error and the configured URL are not echoed, to avoid leaking URL credentials.

`--skip-supertonic`, `--venv-only`, `--doctor`, and `--uninstall` do not trigger the
probe. Existing Git checkouts keep their normal `pull --ff-only` path; the override
is not a migration mechanism. A non-Git destination still requires `--force`, and
a failed access preflight does not delete it even with `--force`.

**This guard does not make the runtime public or complete an external user's TTS
installation.** The maintainer must publish a reviewed compatible runtime, or
explicitly grant access. A GitHub login by itself does not grant permission.
Repository visibility is not changed by this patch.

## Temporary partial installation

From the existing Local-VoiceMode-LLM checkout, to install/verify Parakeet and the
reporter's selected integrations while deliberately leaving Supertonic out:

```bash
./setup.sh --skip-supertonic --integrations=claudecode,opencode
```

This does **not** provide local Supertonic speech output. The previously created
Parakeet launchd definition alone does not prove the transcription API is working;
the selected backend must still pass verification. Do not delete the working
Python environments, use `--force`, or change to `--onnx` to solve repository access.

## Maintainer-approved alternate source

For a fresh clone, `SUPERTONIC_REPO_URL` can select a trusted, compatible copy of
the Supertonic **3** runtime. It must retain `py/requirements.txt`, the
`api.src.main:app` server, the version-3 model downloaders, and (for the default
Apple Silicon path) `py[mlx]`, `supertonic_mlx`, and the MLX downloader. An access
probe is not a compatibility or security audit. Do not put tokens in URLs or logs.

The public `groxaxo/supertonic-express` repository targets Supertonic **2** and is
not a validated drop-in replacement. There is no automatic fallback to that repo.
The model-assets repository `groxaxo/supertonic-3-v2` is not the runtime server.

After a reviewed runtime is publicly accessible, verify an unauthenticated clone
and perform a fresh Apple Silicon installation, a real `/v1/audio/speech` WAV
request, and `/health` inspection. See [macOS verification](macos-repair.md).
Do not mark the original issue resolved based on preflight tests alone.

The separate Windows installer (`setup.ps1`) also references the private runtime;
this narrowly scoped Unix patch does not change Windows behavior.
