# LocalLM Lab Roadmap #

This document collects suggestions/proposals for features and improvements for LocalLM Lab. The developer Ben Chong @ ThisBrainAI LLC may decide to accept, decline or defer suggestions/proposals.

### u/rismay at r/macosprogramming ###
- Instead of running the session just once, have an option to run the same prompt (system+user input) multiple times to capture the variation in the output of the local AI model.
- Selectable configuration: save the user's current configuration and be able to select it.
- Add a verifier step. macOS27-dependency

### ThisBrainAI ideas ###
- Concept of "comma-separate prompts" (CSP) file to feed prompts (system+user input) into the Prompt Playground. The dev.log will capture the behavior of the local AI for each set of prompts.

### Model supply chain (post-1.0 candidates) ###
- **Refuse an unpinned model.** A strict mode where the provider fails instead of downloading a repo that has neither a shipped nor a captured pin (for CI and locked-down CLIs). Today an unpinned repo is pinned on first download.
- **Usage reporting.** Surface token counts and tokens/sec from mlx-swift-lm. The bridge currently drops `GenerateCompletionInfo`. Design notes exist; nothing is implemented.

