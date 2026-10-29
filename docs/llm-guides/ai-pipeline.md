# AI pipeline

## Transports: RubyLLM spike

**Decision: adopted, pinned to `ruby_llm` 2.1.1** (released 2026-10-11, the latest at the start
of the spike). Every criterion in section 19 of the plan passes or has a small fix. None fails.
Live runs: llama.cpp on venus; Ollama, LM Studio and OpenClaw in temporary containers (see
"Local servers in containers"); Gemini through Google's OpenAI-compatible API
(`gemini-3.5-flash-lite`); OpenRouter's chat completions with free models (see "OpenRouter chat
on free models"); and Jev's protocol on OpenCode Zen and OpenRouter's decisions gateway.
Anthropic and OpenAI direct had no key.
Their rows are judged from RubyLLM's source and from WebMock stubs in each provider's documented
shapes, and are marked "not tested live". PR 2 should record live cassettes for them before it
relies on them.

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

Branch: `spike/ruby-llm` (not merged). Tests: `bin/rails test test/models/ai` (147 runs, 1 skip:
the live-only timeout test), and for Jev `bin/rails test test/models/provider/jev_test.rb
test/models/provider/jev_gem_test.rb test/models/provider/jev_gem_live_test.rb` (62 runs). Live server: llama.cpp on venus, `qwen3.6-35b-a3b-mtp` (64k context,
`--jinja`, tool calls on) and `granite-embedding-small-english-r2` (384 dimensions). Neither model
is in RubyLLM's registry. Cassettes are under `test/vcr_cassettes/ai/llama_cpp/`.

### Criteria

| Criterion | Result | Evidence |
|---|---|---|
| Models missing from RubyLLM's registry still work (`assume_model_exists`) | Pass | Every live call used unregistered models. `generate_stubbed_test` "OpenRouter strict mode, model missing from the registry" asserts `ModelNotFoundError` from the registry, then a working call. With `assume_model_exists` the lookup failure falls back to `Model.default` (`lib/ruby_llm/models.rb:198-212`) |
| One URL normaliser handles `/v1` for every compatible server | Small fix: Sure's `Ai::Transport::Http.compatible_base` feeds `openai_api_base` (or `openrouter_api_base`). It adds `/v1` only to a bare host and keeps a URL with a path, because Gemini's compatible base is `/v1beta/openai` | `generate_llama_cpp_test` "base URLs with or without /v1…" (live, `generate_base_url_{0,1,2}`); `gemini_live_test` (live, posts to `/v1beta/openai/chat/completions`); Ollama without `/v1` in `generate_stubbed_test`; `http_test` |
| Prompts, outputs and each tool-loop step reach Langfuse | Pass, through Sure's own `.ai` events, not RubyLLM's | `test/models/ai/live/langfuse_check.rb` against the Langfuse v4 pod: one generation for `generate.ai`, then one `converse.ai` per round (round 1: `user`; round 2: `user>assistant>tool`), with prompt, output and usage, grouped by the correlation id as the session. The pod runs in `events_only` mode, so the check reads `/api/public/v2/observations`. RubyLLM's own OpenTelemetry tracing sends no content and is the `metadata` mode; see "Tracing modes" |
| Tool loops stay under `Ai::Conversation`'s bounds, not the gem's own loop | Pass | `Chat#generate` makes one completion and doesn't run tools (`lib/ruby_llm/chat.rb:196-209`); `#ask`/`#complete` are the gem's loop and aren't used. `converse_test` "llama.cpp streams a tool call…" (live, `converse_tool_round`) expects `RubyLLM::Tool#call` never to run; the last-round and turn-deadline tests cover both bounds |
| The default retries and timeout are overridden by the endpoint's settings | Pass | `errors_test`: 429, 500, 503 and a read timeout give one request with the endpoint's `max_retries: 0`, and four with RubyLLM's defaults (`max_retries = 3`, `request_timeout = 300`, so one call can wait 1,200 s plus backoff). Live: a 2 s timeout against a slow llama.cpp request raises `Ai::Error::Timeout` with one attempt per transport |
| LM Studio's rejection of strict schemas and the `auto` fallback still work | Pass. Live, LM Studio no longer rejects strict schemas, so the fallback is proved by stubs | `lmstudio_live_test` (live, llmster 0.0.25): strict `json_schema` with `reasoning_effort: "low"` is accepted by both transports, `json_object` is refused with a 400 (`'response_format.type' must be 'json_schema' or 'text'`) and becomes `Refused`, and `none` parses the prompted shape. `generate_stubbed_test` "LM Studio rejects strict and json_object…" still proves the chain: strict → 400 → `json_object` without effort → 400 → `none` with the schema example, parsed from a fenced block. A mostly-null answer moves on and keeps the effort |
| Anthropic models that reject a forced tool still return structured output (#4513) | Pass; not tested live | `generate_stubbed_test` "Anthropic forces the tool…" and "Anthropic auto model…": `tool_choice` `tool` vs `auto`, one retry with the reminder, and both attempts billed. Uses `Provider::Anthropic.forced_tool_choice_supported?` |
| `<think>` blocks are stripped | Small fix: Sure's parser strips them; RubyLLM only separates `reasoning_content` | `generate_llama_cpp_test` "an inline think block is stripped…" (live, `reasoning_format: none`, `enable_thinking: true`; the cassette's content holds `</think>`). For chat, inline `<think>` in a stream would reach the user; servers that split reasoning (llama.cpp's default) don't send it inline |
| Tool calls stream on Ollama, llama.cpp and LM Studio | Pass, live on all three | `converse_tool_round` cassettes under `llama_cpp/`, `ollama/` and `lmstudio/`: `get_accounts` is called on round one, Sure runs it, and the answer streams on round two (`ollama_live_test`, `lmstudio_live_test`, through the shared `local_server_live_tests.rb`). On llama.cpp the call arrives as `{` then `}` deltas and is reassembled. `converse_stubbed_test`: Ollama style (whole calls, no `index`) and LM Studio style (fragments keyed by `index`), accumulated by `lib/ruby_llm/protocol/stream_accumulator.rb:125-165` |
| Gemini thought signatures survive gateways | Pass, live through Gemini's OpenAI-compatible API; OpenRouter's `reasoning_details` round trip live with Nemotron, Gemini on OpenRouter stubbed (paid) | `gemini_live_test` (live, `gemini/converse_two_rounds`, `gemini-3.5-flash-lite`, effort `low`): three rounds. Round 2 sends one tool call's `extra_content.google.thought_signature` back and round 3 sends both (`protocols/chat_completions/tools.rb:59-61, 117`). Without them Gemini answers 400 "Function call is missing a thought_signature" (`gemini/round_two_without_signatures`). On OpenRouter, `converse_stubbed_test` "OpenRouter Gemini…" sends `reasoning_details` back on rounds 2 and 3. Small fix: the OpenRouter preset must use RubyLLM's `:openrouter` provider (`providers/openrouter/chat.rb:90-102`); the generic `:openai` provider drops them |
| Every client honours the resolved proxy | Pass | `test/models/ai/live/proxy_check.rb` through a logging forward proxy: RubyLLM's compatible, embed, Anthropic and OpenRouter clients go through it with `HTTPS_PROXY` only and with `HTTP_PROXY` only, and skip it for `NO_PROXY` hosts. The hand-written Anthropic transport (the `anthropic` gem) ignores `HTTPS_PROXY`: Net::HTTP reads only `http_proxy` even for TLS, and the gem takes no proxy option. Also live on Ollama, LM Studio and OpenClaw (see "The proxy with local servers"), where Sure proxies loopback addresses that Ruby's own lookup would not |
| Every error maps onto `Ai::Error` | Pass | `errors_test`. Live on llama.cpp: bad key → `Unauthorized` ("Invalid API Key"), oversized prompt → `ContextTooLong` ("request (287168 tokens) exceeds the available context size (65536 tokens)"), refused port → `Unreachable`. Live on Ollama: an unknown model → 404 → `Refused`; an oversized prompt → `ContextTooLong`. Live on LM Studio: an oversized prompt → `ContextTooLong` (its llama.cpp engine's 400, wrapped as "Engine protocol predict request returned 400: …"). LM Studio's errors are `{"error": "<string>"}`, not OpenAI's `{"error": {"message": …}}`: RubyLLM parses them, and the hand-written transport crashed with a `TypeError` until it was fixed. Live on OpenClaw: a wrong gateway token → 401 → `Unauthorized`, after one attempt. Live on OpenRouter: a wrong key → 401 → `Unauthorized`; a paid model on a key without credits → 402 → `Refused`, after one request; a free model's shared upstream limit → 429 → `RateLimited` (seen three times, not recorded). WebMock: 429, 5xx, 529, OpenAI/OpenRouter, LM Studio and Anthropic context-length wording, and a connect timeout → `Unreachable` |
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
adapter lines on `Compatible`. `agent_test` covers it with stubs, and `agent_live_test` runs it
live against OpenClaw 2026.10.8, whose default agent ran on the llama.cpp server.

- **Headers:** `Chat#with_headers`, from the endpoint's `agent_settings`.
- **The family as `user`:** through `with_provider_options`. RubyLLM's `with_end_user` sends
  `safety_identifier` to the `:openai` provider (`protocols/chat_completions/chat.rb:395-399`),
  which an agent wouldn't read.
- **The URL:** the normaliser strips a trailing `/chat/completions`.
- **Errors and retries:**
  - **Errors:** a refused connection is `Unreachable`, a 502 is `Upstream` (stubbed), and a wrong
    gateway token is `Unauthorized` after one attempt (live).
  - **Retries:** with `max_retries` set on the endpoint, a failed connection is retried before
    the stream starts and never after it, which is what today's client does by hand.
  - **Usage:** OpenClaw sends a usage chunk of zeros, so it comes back as zero tokens.
- **`stream_options` is fine:** RubyLLM always adds `stream_options: {include_usage: true}`, which
  today's client doesn't send. OpenClaw accepts it and answers with the usage chunk.
  `agent_live_test` (live, `openclaw/converse`) streams an answer that depends on the history
  ("Biscuit").
- **Sure's agent headers are ignored, today too.** OpenClaw reads `x-openclaw-agent-id` and
  `x-openclaw-session-key` ([its docs](https://docs.openclaw.ai/gateway/openai-http-api)), not
  `X-Agent-Id` and `X-Session-Key`. Checked live with `openclaw sessions --json`: a request with
  `X-Session-Key: agent:main:main` and `user: "sure-family-spike"` was stored as
  `agent:main:openai-user:sure-family-spike`, and a request with
  `x-openclaw-session-key: agent:main:sure-spike-header` as that key. So every chat in a family
  shares one agent session, keyed by `user`. OpenClaw's docs advise against account-level `user`
  values for that reason. This is in today's client on `main`, not something RubyLLM changes.
- **Speed:** the first request to a new OpenClaw install took four minutes (its first agent run
  on a large system prompt); later ones took about three seconds. A second fresh install, for the
  proxy run, took 27 seconds, so four minutes isn't typical. Today's client times out after
  120 seconds.
- **`Assistant::External::ModelCatalog`** (63 lines, `GET /models`) is deleted by the plan
  (section 8.4), so it wasn't ported.

### Local servers in containers

venus has no discrete GPU, so Ollama and LM Studio ran on CPU (20 cores) with
`Qwen3-30B-A3B-Instruct-2507-Q4_K_M` from local GGUF files: about 7 seconds for a bill setup and
30–45 seconds for a two-round tool turn. Each ran alone, as a rootless podman container with host
networking and the server bound to 127.0.0.1, and was removed afterwards.

- **Ollama 0.40.12** (`docker.io/ollama/ollama`): the GGUFs imported with `ollama create`, which
  took the chat template from the file and reported the `tools` capability. Strict schemas are
  accepted. Embeddings work with `granite-embedding-small-english-r2` (384 dimensions).
- **LM Studio** (llmster 0.0.25, llama.cpp engine 2.41.0): no official image, so a small Ubuntu
  image runs LM Studio's installer; the GGUF is imported with `lms import --symbolic-link` (the
  default moves the file) and loaded with an 8,192-token context. **It answers a request for a
  model it doesn't have with the model it has loaded** (200, the response names the loaded
  model), so a mistyped model name never fails there.
- **OpenClaw 2026.10.8** (`ghcr.io/openclaw/openclaw`): the chat-completions endpoint switched on,
  token auth, loopback bind, and an `openai-completions` provider pointing at llama.cpp. Its keys
  come from env through OpenClaw's secret references, not the config file.
- **VCR:** Sure's setup ignores localhost, so `with_spike_cassette` records it inside its block.
  Addresses and tokens are filtered like the others.
- **A one-off LM Studio failure:** during the proxy run, two of 36 requests failed in 0.2 seconds
  with LM Studio's own "Channel Error … Engine protocol predict request failed: fetch failed",
  each the request straight after a streamed reply. Sure mapped them to `Refused`, so
  they weren't retried. Twelve stream-then-request pairs straight afterwards all succeeded, and
  the cause wasn't found.

### The proxy with local servers

`test/models/ai/live/container_proxy_check.rb` ran every client against each container through
the logging forward proxy, with the server addressed as `127.0.0.1` and as `localhost`:
generate (RubyLLM and hand-written), a streamed converse, embeddings on Ollama, and on OpenClaw
both the spike's agent converse and `Assistant::External::Client` from `main`.

- **Every call worked through the proxy, and streaming isn't buffered:** 39 chunks over the same
  two to three seconds direct and proxied. All the spike's clients agree on every scenario, since
  they share `Ai::Transport::Http.proxy_for`.
- **Sure proxies loopback.** With `HTTPS_PROXY` or `HTTP_PROXY` set and no `NO_PROXY`, requests
  to `127.0.0.1` and `localhost` went to the proxy. Ruby's own lookup (`URI#find_proxy`, which
  Net::HTTP and Faraday use when given no explicit proxy) returns no proxy for loopback, but
  `proxy_for` hands Faraday an explicit one. Through the local test proxy that worked; through a
  proxy on another host, `127.0.0.1` would be that host's loopback, and an egress proxy that
  refuses private addresses would refuse it. The plan's resolver (section 7) should skip loopback
  as Ruby does.
- **`NO_PROXY` matches the host as written.** `127.0.0.1` and `127.0.0.0/8` bypass the proxy for
  `http://127.0.0.1:…` but not for `http://localhost:…`, and `localhost` only for `localhost`.
  The settings page should say so.
- **`main`'s `Assistant::External::Client` resolves the proxy differently.** It reads only the
  URL scheme's own variable, so with only `HTTPS_PROXY` set it goes direct to an `http://`
  gateway where the spike's clients go through the proxy. It matches `NO_PROXY` by name or suffix
  only: with `HTTP_PROXY` and `NO_PROXY=127.0.0.0/8` it still sent `127.0.0.1` to the proxy.
  Moving the agent onto the shared transport gives it the same rules as every other client.

### OpenRouter chat on free models

The key has never bought credits, so `openrouter_chat_live_test` uses `:free` models. They run
through RubyLLM's `:openrouter` provider, with Sure's app headers.

- **Bill setup in strict mode works on both transports** with `recursive/flint-v1.0:free`. Flint
  lists `response_format` but not `structured_outputs`, and the answer still parsed. OpenRouter
  also took a strict schema for `nvidia/nemotron-3.5-lightning:free`, which lists neither. It
  doesn't reject parameters a model lacks (unless the request sets `provider.require_parameters`),
  so a strict request there isn't proof the schema was enforced. Sure's parser is what makes
  these work.
- **A streamed tool round works** on Nemotron 3.5 Lightning: `get_accounts` on round one, run by
  Sure, and the answer streamed on round two. **Round two sends the model's `reasoning_details`
  back**, the live counterpart of the stubbed Gemini test, and the reason the preset uses the
  `:openrouter` provider.
- **Errors:** the paid `nvidia/nemotron-3.5-lightning` answers 402 "Insufficient credits", which
  maps to `Refused` after one request even with `max_retries: 2`. A wrong key is `Unauthorized`.
  `xingchen-agi/xing4.0-29b-a4b:free` answered 429 "temporarily rate-limited upstream" three
  times in a row, which maps to `RateLimited`; it recovered before a cassette could catch it.
  Free models share an upstream pool, so a route that relies on one needs a fallback.
- **Free models reason at length, and effort `low` barely helps.** One bill setup, reasoning
  tokens, one run each:

  | Model | Default | `low` (RubyLLM, hand-written) | `none` |
  |---|---|---|---|
  | Nemotron 3.5 Lightning | 1,517 | 1,449, 1,809 | 0 (112–116 tokens in all, answer correct) |
  | Flint 1.0 | 519–1,077 | 572, 778 | 400 "Reasoning is mandatory for this endpoint and cannot be disabled." |

  Both transports' forms reach the model: RubyLLM sends `reasoning: {effort:}` and the
  hand-written one a top-level `reasoning_effort`. So `none` is the setting that saves tokens, on
  the models that allow it. OpenRouter's own switch, `reasoning: {enabled: false}` in the
  endpoint's `extra_body`, behaves the same on both models and both transports: Nemotron 0
  reasoning tokens (116–119 in all, answer correct), Flint the same 400. On OpenRouter a route
  needs no separate on/off setting; effort `none` covers it. The local servers differ; see
  "Turning reasoning off, server by server". Where a model refuses it, a strict route gets `Refused` with that
  message; an `auto` route would read the 400 as a JSON-mode rejection, drop the effort with
  `response_format` and retry (`JsonMode`, not run live), which works but blames the wrong thing.
  Section 7 should let a route's effort be checked like its JSON mode, and the routes need a
  `max_output_tokens` well above the answer's size.

### Turning reasoning off, server by server

`reasoning_switches_live_test` sends each setting in strict mode with both transports, so a
refusal would surface. The venus llama.cpp server runs with thinking off, so its rows force it
on with `chat_template_kwargs: {enable_thinking: true}` first. Ollama 0.40.13 ran in a temporary
container with Qwen3.6-35B-A3B and gpt-oss-20b from local GGUFs. Completion tokens per bill
setup, one run per transport; the OpenRouter rows from "OpenRouter chat on free models" count
reasoning tokens.

| Setting | llama.cpp, Qwen3.6 | Ollama, Qwen3.6 | Ollama, gpt-oss | OpenRouter, Nemotron | OpenRouter, Flint |
|---|---|---|---|---|---|
| Default | 1,659–2,106 | 1,946–2,199 | 186–215 | 1,517 | 519–1,077 |
| Effort `low` | Ignored | Ignored | Shorter (151–176), and one field missed per run | About the same | About the same |
| Effort `none` | Ignored | **Off** (134–137) | Ignored | **Off** | 400 |
| `reasoning: {enabled: false}` | Ignored | Ignored | Ignored | **Off** | 400 |
| `thinking_budget_tokens: 0` | **Off** (133–134) | — | — | — | — |

- **Ignored means accepted without an error.** Only OpenRouter refuses a setting a model can't
  honour, so a health check can't tell from the status whether a setting worked; it has to
  look for reasoning in the answer.
- **There's no one switch.** Effort `none` works on OpenRouter and on Ollama's hybrid models.
  llama.cpp ignores the OpenAI-style settings and needs its own `thinking_budget_tokens: 0` or
  `chat_template_kwargs: {enable_thinking: false}`. Section 7 should map a route's effort `none`
  per preset (llama.cpp to those fields) rather than send `reasoning_effort` everywhere.
- **gpt-oss can't stop reasoning** but reasons briefly anyway. At effort `low` it lost a field
  in each run: one left the category null ("no category matches Netflix"), the other the name.

### Jev: hand-written, RubyLLM or a Jev gem, outside the criteria

The plan keeps the Jev transport hand-written. Its wire code in `Provider::Jev` (the request,
retries, parsing and usage) is 72 code lines, with 444 lines of tests. The spike checked two
replacements: RubyLLM's `judge`, and `ruby_decision_model`, the most-starred Ruby client for
decision models (59 stars, 20,528 downloads, 0.3.0 from 2026-10-12, no runtime dependencies,
"API may change").

**RubyLLM's `judge`.**

- **OpenCode Zen works on 2.1.1** (`https://opencode.ai/zen/v1/systemone`, `jev-1.13-free`,
  anonymous key `public`). RubyLLM's `typesafe` provider sends Jev's System One payload and
  parses all three answer types (`judge_jev_live_test`, live, `jev/judge_ruby_llm`). A made-up
  key gets 401, mapped to `UnauthorizedError`.
- **OpenRouter doesn't work on 2.1.1, and does on `main`.** 2.1.1 posts to `<base>/v1/systemone`,
  a 404 on OpenRouter, and its OpenAI Decisions payload gets a 400 (`openrouter/judge_ruby_llm`).
  [#1264](https://github.com/crmne/ruby_llm/pull/1264), merged on 2026-10-26 and not yet
  released, adds OpenRouter judgments as a dialect of System One posting to `alpha/decisions`,
  with OpenRouter's reported cost. Judged from the PR and source only: running unreleased code
  from GitHub was blocked in this session, and OpenRouter's Jev models are paid.
- **Paths are still fixed per provider on `main`:** `<base>/v1/systemone` for TypeSafe-style
  servers, `systemone` for Ollama, `../alpha/decisions` for OpenRouter. A gateway at any other
  path can't be reached; Sure's `JEV_ENDPOINT` takes any full URL.
- **No batching or concurrency for judgments.** RubyLLM's batch API covers chats and embeddings
  only, and its fiber concurrency is for tool calls. No issue or PR asks for either.

**The `ruby_decision_model` gem** (`Provider::JevGem`, 54 code lines, replacing the 72).

- It takes over only `decide!`. Everything above the wire stays Sure's: the fan-out, the
  category criteria, the opt-out sentinel and the confidence rules.
- **Sure's 30 Jev tests pass against it, with four overridden** (`jev_gem_test`). All four are
  one difference: the gem rejects a whole response for one malformed answer (a choice or score
  without a confidence, a noul outside 0..1), where Sure keeps the answer with a confidence of 0.
  In Sure's fan-out that rejection would fail every transaction in the batch, so the adapter
  rescues it and withholds only the malformed answer. Only the error message tells that case
  apart from an unparseable body, and the request's usage is lost with it.
- **The adapter has to bring its own transport and URL handling.** The gem's `Net::HTTP` ignores
  Sure's custom CA settings and opens a new connection per request; the adapter injects a Faraday
  transport. The gem appends a fixed path to a base URL, so the adapter subclasses its System One
  provider to post to Sure's full URL.
- **Live on OpenCode Zen** (`jev_gem_live_test`): four transactions categorized correctly through
  `auto_categorize`'s fan-out, and a 401 that isn't retried.
- **It brings** vendor providers Sure doesn't have (OpenAI Decisions, Cloudflare Clef, Perplexity,
  Databricks), retries that honour `Retry-After`, and a request id per response.

**The fan-out is Sure's in every design.** Jev takes one state per request; nothing documents a
multi-state request, and other clients fan out on their side (go-jev's `Map` runs four at a
time). Neither RubyLLM nor the gem fans out, so the batching code is the same whichever client is
underneath, and isn't a reason to keep the wire code hand-written.
`test/models/ai/live/jev_fanout_check.rb` timed 16 easy transactions on OpenCode Zen, one run
each:

| | Concurrency 1 | 4 | 8 | 16 |
|---|---|---|---|---|
| Hand-written, new connection per request | 11.44 s | 3.25 s | 1.73 s | 0.80 s |
| Gem, new connection per request | 11.70 s | 3.14 s | 1.78 s | 0.87 s |
| Gem, kept-alive connection per thread | 6.07 s | 1.82 s | 1.16 s | 0.95 s |

| Packed (gem, kept-alive) | Requests | Time | Input tokens | Right |
|---|---|---|---|---|
| One transaction per request (above) | 16 | 0.80–11.70 s | 6,405 | 16/16 |
| 4 per request, in parallel | 4 | 0.89 s | 3,227 | 16/16 |
| 8 per request, in parallel | 2 | 0.78 s | 2,711 | 16/16 |
| 16 in one request | 1 | 2.83 s | 2,453 | 16/16 |

- **The two clients are equally fast.** The time is the network's.
- **Concurrency scales almost linearly to 16** on this gateway; Sure's default is 8.
- **Reusing connections halves the serial time,** because each request otherwise does a TLS
  handshake. Sure's Faraday client doesn't reuse connections either; a persistent adapter would.
- **Packing is the biggest tuning lever:** several transactions in one state, one `choice`
  question each. Eight per request used 58% fewer input tokens, because the category list is
  sent once per request instead of once per transaction, at the same speed and accuracy. Jev
  bills input tokens only. One request with all 16 was slower. Accuracy was measured on easy
  transactions only; packing could let one transaction's details sway another's answer, so an
  eval should check it before Sure relies on it.

**So the choice is about the 72 lines, not the fan-out.** The gem saves 18 lines for a second
dependency at 0.3.0 with one semantic difference to paper over. RubyLLM's `judge` adds no
dependency once a release carries #1264, but can't reach a gateway at an arbitrary path. Either
way the fan-out, packing and connection reuse are Sure's to tune.

- **A 402 maps to `Ai::Error::Refused`** (`RubyLLM::PaymentRequiredError`). Section 9 doesn't
  name it, but an empty balance is a key's state, like a 401, not a refusal of one request.

### Tracing modes: content and metadata, outside the criteria

Tracing has two modes, and an operator picks one with `Ai::Instrumentation.start_tracing`:

| Mode | Source | What leaves the server | For |
|---|---|---|---|
| `content` (default) | Sure's `.ai` events through `Ai::Instrumentation::LangfuseSubscriber` | Prompts, outputs, usage, route, Sure's error class, session | Debugging prompts and evals in Langfuse |
| `metadata` | RubyLLM's own OpenTelemetry spans through `Ai::Instrumentation::MetadataTracing` | Model, settings, finish reason, tokens (with cached), latency, RubyLLM's error class, session. No prompts, tool results, answers or error bodies | Operators who want cost and latency without sending financial data to a tracing backend |
| `off` | — | Nothing | — |

The two never run together, or Langfuse would get each generation twice, once without content.
Usage rows and the debug log are local subscribers and run in every mode.

**Why `metadata` is RubyLLM's job.** RubyLLM 2.1.1 has no Langfuse integration, but
`RubyLLM::OpenTelemetry.enable` turns its events into spans on the global OpenTelemetry tracer,
using the GenAI semantic conventions. `lib/ruby_llm/open_telemetry/attributes.rb` sets only the
operation, provider, model, temperature, max tokens, stream flag, finish reason and token counts.
Nothing in the gem sets `gen_ai.input.messages`, `gen_ai.output.messages` or Langfuse's
`langfuse.observation.input` and `output`, and a failure records only `error.type`, the class name.
So the privacy comes from the gem not having the code to send content, not from a setting that
someone could flip on.

**Sure's part is small** (`app/models/ai/instrumentation/metadata_tracing.rb`, 19 lines, plus 12 for the mode switch in `app/models/ai/instrumentation.rb`):

- an OpenTelemetry tracer provider exporting OTLP, set up by the standard
  `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` and `OTEL_EXPORTER_OTLP_TRACES_HEADERS`, so the backend can
  be Langfuse, Tempo, Jaeger or OpenObserve;
- a span processor that stamps the job's correlation id as `session.id` on every span. RubyLLM
  can't set a session, and Langfuse v4 doesn't copy a parent span's session to its children, so
  without it the spans don't group by job. `RubyLLM.workflow` only adds a parent span.

**Evidence.**

- `test/models/ai/metadata_tracing_test.rb` replays the llama.cpp `generate_ruby_llm` and
  `converse_tool_round` cassettes into an in-memory exporter. It expects three `chat` spans with
  the model, usage and session, and checks that no span name, attribute, event or status contains
  the charges, categories, instructions, question, tool result or answer. A 500 whose body echoes
  a charge leaves only `error.type = RubyLLM::ServerError`.
- `test/models/ai/live/langfuse_otel_check.rb` runs the `metadata` mode live against the Langfuse
  pod. Langfuse groups the three generations under the job's session, with model, usage
  (including cached tokens) and latency, and empty input and output.

**What `metadata` loses:** the route and prompt key, Sure's `Ai::Error` class (it gets RubyLLM's),
and errors raised before RubyLLM is called (`Unavailable`, `Busy`). The global tracer provider is
also shared with any other OpenTelemetry instrumentation Sure adds later, which could carry
content of its own.

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

- `openai_use_system_role = true` on every compatible endpoint, OpenRouter's included: its
  provider reads the same setting. Otherwise RubyLLM sends system prompts with the `developer`
  role (`protocols/chat_completions/chat.rb:376-383`). The OpenRouter run first went out as
  `developer`, because the spike set it only for `:openai`; the free models answered anyway.
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

- Live runs against Anthropic and OpenAI direct (the Responses API and vector stores), which had
  no key, and OpenRouter's paid chat models, such as Gemini, which need credits.
- The `auto` fallback chain against a live server that rejects strict schemas: none of the three
  local servers does any more.
- Gemini thought signatures through other gateways, such as LiteLLM.
