# jev-serve

`jev-serve` now lives in the JevDK project: **[github.com/ancientcomputing/jevdk](https://github.com/ancientcomputing/jevdk)**.
Source and releases are there, not here.

`jev-serve` answers hosted Jev's HTTP API on your Mac: it takes the same requests as TypeSafe's Jev on
OpenRouter (`POST /api/alpha/decisions`) and Featherless's Simple Jev (`POST /v1/classifier`) and answers them
with **OpenJev**, the SDK's decider, on a local MLX model. Code that already calls hosted Jev, in any language,
switches to private, free, on-device decisions by changing its base URL.

- **Get it:** it comes with JevDK. Download [the latest JevDK release](https://github.com/ancientcomputing/jevdk/releases/latest),
  move JevDK to Applications, then choose **JevDK → Install jev-serve Command…**.
- **Source and usage:** [ancientcomputing/jevdk](https://github.com/ancientcomputing/jevdk).
- **Guide:** [thisbrain.ai/locallm/jdk-guide.html](https://thisbrain.ai/locallm/jdk-guide.html), and
  [Decision models (Jev) in your app](https://thisbrain.ai/locallm/jev.html) if decision models are new to you.
