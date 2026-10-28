# AI pipeline

## Transports: RubyLLM spike

**Decision: adopted, pinned to `ruby_llm` 2.1.1** (released 2026-10-11, the latest at the start
of the spike). Every criterion in section 19 of the plan passes or has a small fix. None fails.
Live runs: llama.cpp on venus, Gemini through Google's OpenAI-compatible API
(`gemini-3.5-flash-lite`), and Jev's protocol on OpenCode Zen and OpenRouter's decisions gateway.
LM Studio, Ollama, Anthropic and OpenAI direct had no server or key, and the OpenRouter key has no
credits for chat models. Their rows are judged from RubyLLM's source and from WebMock stubs in
each provider's documented shapes, and are marked "not tested live". PR 2 should record live
cassettes for them before it relies on them.

RubyLLM doesn't save lines in `generate`; its adapter is longer than the hand-written one. The
case for it is everything else:

- **Chat streaming:** one parser covers chat completions, Anthropic and the Responses API, and
  it preserves Gemini's `reasoning_details` and Anthropic's thinking signatures between rounds.
  Today's chat transport is about 855 lines.
- **One HTTP stack:** Faraday takes an explicit proxy for every provider. The `anthropic` gem
  can't take one (see the proxy row).
- **Unknown models:** `assume_model_exists` handles models missing from the registry.

Sure keeps the tool loop, the JSON-mode policy, error mapping, instrumentation and the routing
around it.

Branch: `spike/ruby-llm` (not merged). Tests: `bin/rails test test/models/ai` (70 runs, 1 skip:
the live-only timeout test). Live server: llama.cpp on venus, `qwen3.6-35b-a3b-mtp` (64k context,
`--jinja`, tool calls on) and `granite-embedding-small-english-r2` (384 dimensions). Neither model
is in RubyLLM's registry. Cassettes are under `test/vcr_cassettes/ai/llama_cpp/`.

### Criteria

| Criterion | Result | Evidence |
|---|---|---|
| Models missing from RubyLLM's registry still work (`assume_model_exists`) | Pass | Every live call used unregistered models. `generate_stubbed_test` "OpenRouter strict mode, model missing from the registry" asserts `ModelNotFoundError` from the registry, then a working call. With `assume_model_exists` the lookup failure falls back to `Model.default` (`lib/ruby_llm/models.rb:198-212`) |
| One URL normaliser handles `/v1` for every compatible server | Small fix: Sure's `Ai::Transport::Http.compatible_base` feeds `openai_api_base` (or `openrouter_api_base`). It adds `/v1` only to a bare host and keeps a URL with a path, because Gemini's compatible base is `/v1beta/openai` | `generate_llama_cpp_test` "base URLs with or without /v1…" (live, `generate_base_url_{0,1,2}`); `gemini_live_test` (live, posts to `/v1beta/openai/chat/completions`); Ollama without `/v1` in `generate_stubbed_test`; `http_test` |
| Prompts, outputs and each tool-loop step reach Langfuse | Pass, through Sure's own `.ai` events, not RubyLLM's | `test/models/ai/live/langfuse_check.rb` against the Langfuse v4 pod: one generation for `generate.ai`, then one `converse.ai` per round (round 1: `user`; round 2: `user>assistant>tool`), with prompt, output and usage, grouped by the correlation id as the session. The pod runs in `events_only` mode, so the check reads `/api/public/v2/observations` |
| Tool loops stay under `Ai::Conversation`'s bounds, not the gem's own loop | Pass | `Chat#generate` makes one completion and doesn't run tools (`lib/ruby_llm/chat.rb:196-209`); `#ask`/`#complete` are the gem's loop and aren't used. `converse_test` "llama.cpp streams a tool call…" (live, `converse_tool_round`) expects `RubyLLM::Tool#call` never to run; the last-round and turn-deadline tests cover both bounds |
| The default retries and timeout are overridden by the endpoint's settings | Pass | `errors_test`: 429, 500, 503 and a read timeout give one request with the endpoint's `max_retries: 0`, and four with RubyLLM's defaults (`max_retries = 3`, `request_timeout = 300`, so one call can wait 1,200 s plus backoff). Live: a 2 s timeout against a slow llama.cpp request raises `Ai::Error::Timeout` with one attempt per transport |
| LM Studio's rejection of strict schemas and the `auto` fallback still work | Pass; LM Studio not tested live | `generate_stubbed_test` "LM Studio rejects strict and json_object…": strict → 400 → `json_object` without effort → 400 → `none` with the schema example, parsed from a fenced block. A mostly-null answer moves on and keeps the effort |
| Anthropic models that reject a forced tool still return structured output (#4513) | Pass; not tested live | `generate_stubbed_test` "Anthropic forces the tool…" and "Anthropic auto model…": `tool_choice` `tool` vs `auto`, one retry with the reminder, and both attempts billed. Uses `Provider::Anthropic.forced_tool_choice_supported?` |
| `<think>` blocks are stripped | Small fix: Sure's parser strips them; RubyLLM only separates `reasoning_content` | `generate_llama_cpp_test` "an inline think block is stripped…" (live, `reasoning_format: none`, `enable_thinking: true`; the cassette's content holds `</think>`). For chat, inline `<think>` in a stream would reach the user; servers that split reasoning (llama.cpp's default) don't send it inline |
| Tool calls stream on Ollama, llama.cpp and LM Studio | Pass on llama.cpp (live); Ollama and LM Studio not tested live | `converse_tool_round` cassette: the call arrives as `{` then `}` deltas and is reassembled. `converse_stubbed_test`: Ollama style (whole calls, no `index`) and LM Studio style (fragments keyed by `index`), accumulated by `lib/ruby_llm/protocol/stream_accumulator.rb:125-165` |
| Gemini thought signatures survive gateways | Pass, live through Gemini's OpenAI-compatible API; OpenRouter stubbed (no credits) | `gemini_live_test` (live, `gemini/converse_two_rounds`, `gemini-3.5-flash-lite`, effort `low`): three rounds. Round 2 sends one tool call's `extra_content.google.thought_signature` back and round 3 sends both (`protocols/chat_completions/tools.rb:59-61, 117`). Without them Gemini answers 400 "Function call is missing a thought_signature" (`gemini/round_two_without_signatures`). On OpenRouter, `converse_stubbed_test` "OpenRouter Gemini…" sends `reasoning_details` back on rounds 2 and 3. Small fix: the OpenRouter preset must use RubyLLM's `:openrouter` provider (`providers/openrouter/chat.rb:90-102`); the generic `:openai` provider drops them |
| Every client honours the resolved proxy | Pass | `test/models/ai/live/proxy_check.rb` through a logging forward proxy: RubyLLM's compatible, embed, Anthropic and OpenRouter clients go through it with `HTTPS_PROXY` only and with `HTTP_PROXY` only, and skip it for `NO_PROXY` hosts. The hand-written Anthropic transport (the `anthropic` gem) ignores `HTTPS_PROXY`: Net::HTTP reads only `http_proxy` even for TLS, and the gem takes no proxy option |
| Every error maps onto `Ai::Error` | Pass | `errors_test`. Live on llama.cpp: bad key → `Unauthorized` ("Invalid API Key"), oversized prompt → `ContextTooLong` ("request (287168 tokens) exceeds the available context size (65536 tokens)"), refused port → `Unreachable`. WebMock: 429, 5xx, 529, OpenAI/OpenRouter, LM Studio and Anthropic context-length wording, and a connect timeout → `Unreachable` |
| The Responses API and vector stores work through it, or the `responses_api` path stays hand-written | Small fix: Responses `generate` goes through RubyLLM; vector stores stay on `ruby-openai`; not tested live (no OpenAI key) | `generate_stubbed_test` "an endpoint with responses_api…": `text.format` strict JSON schema, `reasoning.effort`, `store: false`. RubyLLM's Responses protocol is stateless by design (`lib/ruby_llm/protocols/responses.rb:5-8`) and never sends `previous_response_id`. It has no vector store calls, only the `file_search` server tool, so `VectorStore::Openai` keeps `ruby-openai` |
| Lines removed for `bill_setup` against the hand-written version | Reported below | RubyLLM's `generate` is 26 lines longer than the hand-written one |

Chatwoot's #16078 kept audio transcription and embeddings on their dedicated OpenAI endpoints
because the Responses API it moved text inference to has no equivalent for them. It wasn't a
judgement of RubyLLM: Chatwoot still embeds through `RubyLLM.embed`
(`enterprise/app/services/captain/llm/embedding_service.rb`), without `assume_model_exists`.
`embed` over RubyLLM passes here: `embed_test` (live, `embed`) returns two 384-dimension vectors
and one `embed.ai` event.

### The external assistant (agent mode), outside the criteria

Today's `Assistant::External::Client` (141 code lines) speaks plain OpenAI chat completions over
SSE. Its extras are the `X-Agent-Id` and `X-Session-Key` headers, `user: "sure-family-<id>"` in
the body, the history with no tools, and a full `…/chat/completions` URL. Over RubyLLM that's 10
adapter lines on `Compatible`: `agent_test` (stubbed; no agent was running during the spike).

- **Headers:** `Chat#with_headers`, from the endpoint's `agent_settings`.
- **The family as `user`:** through `with_provider_options`. RubyLLM's `with_end_user` sends
  `safety_identifier` to the `:openai` provider (`protocols/chat_completions/chat.rb:395-399`),
  which an agent wouldn't read.
- **The URL:** the normaliser strips a trailing `/chat/completions`.
- **Errors and retries:**
  - **Errors:** a refused connection is `Unreachable` and a 502 is `Upstream`.
  - **Retries:** with `max_retries` set on the endpoint, a failed connection is retried before
    the stream starts and never after it, which is what today's client does by hand.
  - **Usage:** none is reported, so it comes back as zero tokens.
- **A risk to check live:** RubyLLM always adds `stream_options: {include_usage: true}` to a
  streamed request, and today's client doesn't. An agent that rejects unknown parameters would
  answer 400. `with_provider_options` can add fields but not remove them.
- **`Assistant::External::ModelCatalog`** (63 lines, `GET /models`) is deleted by the plan
  (section 8.4), so it wasn't ported.

### `judge` (Jev's protocol), outside the criteria

The plan keeps the Jev transport hand-written. RubyLLM 2.1.1 has a `judge` API, so the spike
checked it against two gateways.

- **OpenCode Zen works** (`https://opencode.ai/zen/v1/systemone`, `jev-1.13-free`, anonymous key
  `public`). RubyLLM's `typesafe` provider sends Jev's System One payload: `state` (Jev's
  transaction object, unchanged) and a hash of `noul`/`choice`/`score` questions. It parses all
  three answers: `judge_jev_live_test` (live, `jev/judge_ruby_llm`). Sure's `Provider::Jev` gets
  the same `choice` from the same endpoint (`jev/judge_provider_jev`). A made-up key gets 401
  "Invalid credential", which RubyLLM maps to `UnauthorizedError`.
- **OpenRouter doesn't.** RubyLLM's System One path is fixed to `<base>/v1/systemone`
  (`protocols/system_one/judgments.rb`), and OpenRouter serves decisions at
  `/api/alpha/decisions`, so the request gets a 404. RubyLLM's OpenAI Decisions protocol does
  reach that path, but OpenRouter rejects its payload (`input` plus an array of questions) with a
  400. Both are recorded in `openrouter/judge_ruby_llm`. Sure's `JEV_ENDPOINT` is a full URL and
  reaches either gateway.
- **Respan `span-01-lite` on OpenRouter:** the `:free` variant answers `noul` on a string state,
  and rejects Jev's transaction object with a 400 ("state must be a string or…"). The paid
  variant takes `noul`, `choice` and `score`, but returned 402 "Insufficient credits" for this
  key, so it wasn't run.
- **So a `judge` over RubyLLM would serve TypeSafe and OpenCode Zen, but not OpenRouter.** Jev's
  fan-out over `parallel_requests` stays Sure's either way, since RubyLLM makes one request per
  `judge`. Keeping Jev hand-written, as planned, costs nothing and keeps every gateway.
- **A 402 maps to `Ai::Error::Refused`** (`RubyLLM::PaymentRequiredError`). Section 9 doesn't
  name it, but an empty balance is a key's state, like a 401, not a refusal of one request.

### Lines of code for bill setup

Code lines only: blank and comment-only lines aren't counted.

| | Lines | What |
|---|---|---|
| Today | 559 | Both `BillSetupSuggester`s (137, 139), `Anthropic::Concerns::StructuredOutput` (37), both `UsageRecorder`s (93, 91), `Provider::Anthropic`'s structured-output helpers (16), and the two `suggest_bill_setup` methods (23, 23) |
| Shared by both new versions | 286 | `Transport::Base`, `Transport`, `Http`, `JsonMode`, `Ai::Error`, `Ai::Usage`, `Ai::Schema`, `Ai::Generation`, `SuggestBillSetup` and the prompt file |
| Hand-written `generate` | 97 | `HandWritten::Compatible` (45) and `HandWritten::Anthropic` (52), over `ruby-openai` and `anthropic` |
| RubyLLM `generate` | 123 | `Compatible` (36), `Anthropic` (33) and the shared `RubyLlmAdapter` (54), without their `converse` and `embed` code |

The redesign takes bill setup from 559 lines to 383 (hand-written) or 409 (RubyLLM). The JSON-mode
policy is Sure's in both versions and is counted once. RubyLLM's `converse` and `embed` add 51
adapter lines plus 47 for `Ai::Conversation`, against about 855 lines of today's chat transport.
Today's code does more (`previous_response_id`, usage recording), so treat that as context, not a
measurement.

### Small fixes in Sure's adapter

- `openai_use_system_role = true` on every compatible endpoint. Otherwise RubyLLM sends system
  prompts with the `developer` role (`protocols/chat_completions/chat.rb:376-383`).
- Always pass `protocol:`. RubyLLM's OpenAI provider defaults to the Responses API.
- Set `openrouter_app_name` and `openrouter_app_url`. Otherwise OpenRouter sees "RubyLLM" and
  `https://rubyllm.com`.
- Check that `embed` returns one vector per text. 2.1.1 doesn't (#1269, fixed after the release).
- Check the turn deadline in the stream callback. Faraday's timeout is per read, so a stream that
  keeps trickling never trips it. Capping each request's timeout at the turn's remaining time
  would create a new cache key every call in RubyLLM's 64-entry connection cache.
- Send the final round with the tools still declared and `tool_choice: :none`.

### What the owner watches on upgrade

- **Pin exactly** (`gem "ruby_llm", "2.1.1"`). Releases are fast: 2.0.0 on 2026-09-18, 2.1.0 on
  10-08 and 2.1.1 on 10-11. About 47 issues were closed in the 17 days after 2.1.1. One
  maintainer has 1,752 commits; the next contributor has 138.
- **Use only the public API:** `RubyLLM.context`, `Chat#generate`, `#add_message`, the `with_*`
  setters, `Message#to_h`/`.new`, `RubyLLM::Tool` and `.embed`. The maintainer declines to open
  the loop's internals (#1291) and to add a supported opt-out from usage recording (#1071).
- **The railtie's side effects in Rails:**
  - It mixes `acts_as` into `ActiveRecord::Base`.
  - It sets `ActiveSupport::Notifications` as the instrumenter, so `*.ruby_llm` events publish
    in Sure's process.
  - It adds an `after_destroy` hook to every Active Storage blob, guarded by
    `ruby_llm_provider_files`.
  - It installs a usage ledger. Every call checks out a database connection and checks whether
    `ruby_llm_usages` exists. Don't create that table. #1071 says not to rely on
    `Usage.ledger = nil`.
- **Usage counts.** RubyLLM's `input_tokens` excludes cached tokens; the raw APIs include them.
  Fixes after 2.1.1 change the counts: #1060 (Anthropic streaming input tokens), #1075 (zero
  input when cached exceeds prompt) and #1265 (vLLM cache writes).
- **Defaults Sure overrides,** in case they change: `max_retries`, `request_timeout`, the
  `developer` role, the Responses protocol as OpenAI's default, OpenRouter's app headers, and
  the Responses API's `store: false`.
- **Re-run** `bin/rails test test/models/ai`, then re-record with `SPIKE_RECORD=1` against live
  servers.

### Not judged in the spike

- Live runs against LM Studio, Ollama, Anthropic and OpenAI direct (the Responses API and vector
  stores), which had no server or key, and OpenRouter's chat models, which need credits.
- Gemini thought signatures through other gateways, such as LiteLLM.
- Langfuse from RubyLLM's own OpenTelemetry support. Sure's subscriber was enough.
