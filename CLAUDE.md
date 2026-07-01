# Claude Guidance

## Project

- This repository is `みちあかり / Michiakari`, a Flutter app and ESP32 sketch for a BLE-controlled navigation lantern.
- Keep Mapbox access tokens out of the repository. Use `--dart-define=ACCESS_TOKEN=...` when running the app.
- Do not commit build outputs, generated caches, local IDE state, signing credentials, or Apple Developer Team IDs.

## Commit Message Mood Prefix

When creating a commit, infer the current mood from the recent conversation and development context.

Prefix the commit subject with exactly one face emoji that matches that mood, then keep the rest of the message clear and conventional.

Prefer these mappings:

- 🤬 furious: "くそ怒ってる", "ブチギレ", "激怒", repeated breakage, or strong exasperation.
- 😡 angry: irritation, anger, "イライラ", "ムカつく", "腹立つ".
- 😤 frustrated: stubborn failure, regret, "悔しい", "納得いかない".
- 😭 sad: sadness, exhaustion, "つらい", "しんどい", "絶望".
- 😰 anxious: urgency, panic, "やばい", "急ぎ", "間に合わない".
- 🤔 thinking: uncertainty, confusion, "うーん", "迷う", "わからない".
- 😄 happy: playful, pleased, "いいね", "楽しい", "かわいい".
- 😎 proud: success, completion, "できた", "やった", "勝ち".
- 😌 calm: relief, settled mood, "安心", "落ち着いた".
- 😐 neutral: no clear mood.

Use only one emoji at the start of the first line, for example:

```text
😄 feat: add mood-aware commit guidance
```

Do not add a second mood emoji if the proposed commit message already starts with one.

If the repository has a stricter documented commit format that conflicts with emoji prefixes, follow the repository rule and mention that choice.
