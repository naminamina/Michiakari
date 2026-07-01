# Personal Codex Guidance

## Project

- This repository is `みちあかり / Michiakari`, a Flutter app and ESP32 sketch for a BLE-controlled navigation lantern.
- Keep Mapbox access tokens out of the repository. Use `--dart-define=ACCESS_TOKEN=...` when running the app.
- Do not commit build outputs, generated caches, local IDE state, signing credentials, or Apple Developer Team IDs.

## Commit Message Mood Prefix

When creating a commit, infer the current mood from the recent conversation and development context.

Prefix the commit subject with exactly one face emoji that matches that mood, then keep the rest of the message clear and conventional.

Choose the emoji freely. Do not limit yourself to a fixed lookup table. Use the recent conversation, wording, punctuation, pace, and development outcome to infer the emotional color, then pick the one face emoji that best captures it.

The emoji can be subtle, dramatic, funny, relieved, proud, confused, nervous, affectionate, chaotic, or deadpan. Prefer specificity over generic positivity. For example, a smooth release might be 🥳, a clever debugging breakthrough might be 🤯, secret-cleanup work might be 🤐, a tired maintenance chore might be 😮‍💨, a playful request might be 😄, and a genuinely neutral change might be 😐. These are examples, not a required list.

If the user explicitly expresses a mood, follow that. If the mood is mixed, choose the dominant recent feeling. If there is no emotional signal, choose a restrained neutral or mild face.

Use only one face emoji at the start of the first line, for example:

```text
😄 feat: add mood-aware commit guidance
```

Do not add a second mood emoji if the proposed commit message already starts with one.

If the repository has a stricter documented commit format that conflicts with emoji prefixes, follow the repository rule and mention that choice.
