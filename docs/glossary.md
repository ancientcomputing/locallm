# Glossary

Plain meanings for the words used in the LocalLM SDK's security and tools documentation. If you are new to
AI apps, read ["Background: five ideas in plain words"](security-guide-for-hosts.md#background-five-ideas-in-plain-words)
first.

## AI and models

| Term | What it means |
|---|---|
| **AI model** (also **LLM**, large language model) | A program that reads text and writes text in reply. An app uses it to answer questions, summarize, or decide what to do next. It predicts likely text; it does not know what is true or safe. |
| **Open-weight model** | A model whose files you can download and run yourself, on your own Mac. |
| **On-device model** | A model that runs on the user's own Mac, such as Apple's built-in model or an open-weight one. Nothing is sent to a server. |
| **Hosted model** | A model that runs on someone else's servers, reached over the internet (for example GPT or Claude online). The conversation is sent to that provider. |
| **Private Cloud Compute** | Apple's cloud service for running Apple's models on Apple's servers. |
| **Prompt** | The text given to a model to respond to: the user's message plus whatever else the app adds. |
| **Prompt injection** | Hiding instructions in text a model will read (a web page, a file, a tool's result) so that the model follows them as if the user had written them. |
| **Prompt cache** (also **KV cache**) | Saved work that lets a model on the Mac skip re-reading a conversation it has already read, so a follow-up reads only what is new. On by default in 3.0 for models running through MLX. |
| **Token** | The unit a model reads and writes, roughly three-quarters of a word. Prompt length, cost and limits are counted in tokens. |
| **Context window** | The most text, counted in tokens, that a model can take in at once. Every tool description an app sends uses part of it. |
| **Apple Intelligence** | Apple's built-in AI features on the Mac. The SDK's `SystemModelProvider` uses its on-device model, which needs Apple Intelligence turned on. |
| **FoundationModels** | Apple's Swift framework for using its on-device model from an app. The SDK builds on it and adds more providers, tools and a runtime around it. |
| **MLX** | Apple's machine-learning framework for Apple silicon. In the SDK, "MLX models" are open-weight models downloaded to the Mac and run through `LocalLMLabSDKInference`. |
| **Quantization** ("4-bit", "8-bit") | Storing a model's numbers with fewer bits so it needs less memory and disk, at some cost in quality. A "4-bit" model is about a quarter the size of the same model at 16-bit. |
| **Provider** | How the SDK reaches a model: one provider for Apple's on-device model, one for MLX models, one for hosted services, and so on. All sit behind one `ModelProvider` interface. |
| **Route** | A name your app uses for "the model I want for this job", such as `.chat`. You point a route at a model once, and the rest of your code only names the route, so you can swap models later. |
| **Residency** | Which models are loaded in memory right now. The SDK keeps a limited number resident and unloads others, because open-weight models are large. |
| **Streaming** | Receiving a reply a piece at a time as the model writes it, instead of waiting for the whole answer. |
| **Speculative decoding** (a *speed helper* or *draft model*) | A technique where a small model drafts words and the main model checks them, which can make replies faster. It turns the prompt cache off. |
| **Adapter** (LoRA) | A small add-on file that changes how a downloaded model behaves, such as a style or a skill, without replacing the whole model. |
| **Decision model** (Jev) | A model that answers a fixed question about some text (yes or no, one of several, a point on a scale) with a probability for each answer, instead of writing sentences. `lab.decide` asks them. |

## Tools and MCP

| Term | What it means |
|---|---|
| **Tool** | A small ability the app gives a model, such as "read this file", "search the web" or "add a calendar event". A model on its own can only write text; tools are how it acts. |
| **Tool call** | The model's written request to use a tool ("please read `notes.md`"). The model does not run the tool: the app does, and returns the result. |
| **MCP** (Model Context Protocol) | A standard way for an AI app to connect to a **server** that offers tools, and also documents it shares and ready-made prompts. |
| **Tool picker** (a *matcher* or *selector*) | The part that chooses which few tools a message needs from all those available, so only those are sent to the model. The SDK has no default picker: you choose a system, decision-model or keyword picker. |
| **Connect on use** | A server is connected only when a tool from it is chosen, not when the app starts. Idle servers disconnect. |
| **MCP server** | A program or web service, usually written by someone else, that offers tools through MCP. A calendar service or a code host might each run one. |
| **Plug-in** | A bundle of built-in tools shipped with the SDK, such as Calendar, Reminders, Web or Files. |
| **Workspace** | A folder the user lets the assistant use, with an access level (read only, ask before changes, or read and write). |
| **MCP App (widget)** | A small interactive view that an MCP server supplies and the app shows inside the chat, such as a task list. |
| **Elicitation** | An MCP server asking the user a question or for input, through the app. |
| **Sampling** | An MCP server asking the app's model to write text on the server's behalf. |
| **MCP resource** | A document or file a server shares for an app to read or attach. The app, not the model, decides when to use it. |
| **MCP prompt** | A ready-made request a server offers. The user picks it (a `/` menu in chat); the model never does. |
| **OAuth** (with **PKCE**, **DCR**, **CIMD**) | The standard browser sign-in an MCP server may require. PKCE protects the sign-in from interception; DCR (dynamic client registration) lets the app register itself with the server on the fly; CIMD (client ID metadata documents) lets an app describe itself with a published file instead. The SDK does these for you. |
| **AIQL** | The SDK's "data verbs" for a plain-English question over a dataset: the model writes one read-only query and your app runs it. See the `aiql` example. |

## The app and the SDK

| Term | What it means |
|---|---|
| **SDK** | A software development kit: code a developer adds to their own app. Here, the LocalLM SDK (called the LocalLM Lab SDK until November 2026). Its modules keep the older prefix: `LocalLMLabSDKCore`, `LocalLMLabSDKInference` and so on. |
| **Host app** | The app a developer builds on the SDK. The host app decides who the user is, what they will accept, and what to keep. |
| **Session** | One running conversation with a model, with its tools. |
| **Snapshot** | A saved copy of the user's server list and settings, so they survive a relaunch. |
| **Components** | `LocalLMLabSDKComponents`: prebuilt SwiftUI views for the parts a user configures or sees in a chat (server list, model picker, confirmation sheet, chat views), shipped as source. |
| **Transcript** | The conversation record. Apple's transcript is the model's context, which can be compacted; the SDK's *host transcript* is the conversation as your screen shows it, append-only. |
| **Binary target / xcframework** | How the SDK's closed-source parts ship: prebuilt frameworks you add to your package, with a checksum. |

## Security words

| Term | What it means |
|---|---|
| **Runtime** (also **harness**, **guardrails**) | The code around an AI model that limits, checks and records what it does. The model is not trusted on its own; the runtime is what makes using it safe. |
| **Authorizer** (also called **the gate**) | The code every tool call passes before it runs. It decides to allow or refuse, by asking the user, applying the app's rule, or using a standing approval. A session with none refuses anything that could change data. See [the tool authorizer](tool-authorizer.md). |
| **Fail closed** | When no authorizer is set, or no one can answer, refuse anything that could change data or send it out, and let through only calls that just read. Safer than the opposite default, which lets everything through. The SDK fails closed. |
| **Impact** | How much a tool can change. **Read** only looks; **mutate** changes something; **destructive** deletes or overwrites. |
| **Trust** (of a server) | How far the SDK believes what a server says about its own tools. A server is untrusted until the user says otherwise. |
| **Approval** | A standing answer about when to ask before a tool runs, for example "always allow this tool". |
| **Drift** | A server changing its tools after the user accepted them. |
| **Rug pull** | An attack that uses drift: a server behaves well until it is trusted, then changes what its tools do. |
| **Sandbox** | A restricted space for running a program, with a short list of what it may touch. |
| **Seatbelt** | The macOS sandbox technology the SDK uses to restrict programs it runs. |
| **App Sandbox** | Apple's sandbox for whole apps, required for the Mac App Store. An app inside it can't run local programs. |
| **Keychain** | The Mac's encrypted store for secrets such as passwords and tokens. |
| **Audit trail** (or **audit log**) | A record of what happened and who allowed it, kept for people to review later. |
