---
description: Tjek om Claude-, Gemini- (agy) og Codex-CLI'erne er klar til peer review, og tilbyd installation hvis noget mangler
disable-model-invocation: true
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
---

Kør:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/llm-peer-review/scripts/preflight.sh" check
```

`preflight.sh check` afslutter med exit 1, når noget er `MISSING`. Det er forventet og ikke en kommandofejl.

Videregiv outputtet til brugeren uændret (én linje pr. komponent, `ok` eller `MISSING …`).

Er alt `ok`, så sig kort, at peer review er klar. Ellers, for hver `MISSING`-linje, foreslå rettelsen og installér kun efter bekræftelse:

- Brug `AskUserQuestion` én gang pr. manglende komponent med to valg: installér (`(Recommended)` på det første) eller `Spring over`. Installér aldrig uden at brugeren har bekræftet.
- `agy` (Gemini via Antigravity CLI), officiel installer:
  ```bash
  curl -fsSL https://antigravity.google/cli/install.sh | bash
  ```
- `codex`:
  ```bash
  npm install -g @openai/codex
  ```
- Authentication: bed brugeren køre CLI'en interaktivt én gang (`!agy` for Gemini, `!codex login` for Codex), så login gemmes. Kør ikke login for brugeren.
- Mangler en anden komponent (fx `claude`, `python3`, `jq`), forklar hvad der mangler og hvordan det typisk installeres, men installér ikke uopfordret.

Efter en installation, kør preflight-kommandoen igen og vis det nye output. Blev installationen sprunget over, så vis det oprindelige output og nævn, at reviews med de manglende stemmer fejler, indtil de er installeret (`--voices` kan vælge de stemmer, der er klar).
