# JS/TS idle memory footprint: defaults vs memory-optimized

**Researched:** 2026-08-21  
**Question:** What would be the idle memory footprint of a JS/TS workload optimized towards limiting memory consumption vs industry defaults?  
**Scope:** Server-side Node.js (V8) first; Deno and Bun only where first-party docs or reproducible local measurement apply. Browser JS/TS (Chromium multi-process model) is out of scope except a one-line contrast. No Propraetor-specific sizing experiment beyond host measurements recorded below.  
**Method:** Primary sources only — Node.js API/CLI docs and source (`environment.cc`, options handling), V8 heap sizing source and pointer-compression notes, AWS Lambda / Google Cloud Run memory defaults, Deno/Bun official API docs. Secondary blogs used only as leads. Idle RSS numbers that vendors do not publish are either **Absent (documented)** or **Empirical (this host)** — never invented from third-party write-ups.

---

## Confidence legend

| Label | Meaning |
| --- | --- |
| **High** | Direct from owning docs or source; reproducible on this host where labeled Empirical |
| **Medium** | Clear consequence of primary material, but exact MiB depends on OS/build/app |
| **Inference** | Operator-facing synthesis; not a vendor normative claim |
| **Absent** | Primary sources do not publish this figure |

---

## Verdict (operator-facing)

**Heap limit ≠ idle RSS.** Untuned Node on a typical laptop/server sets a **multi‑GiB V8 old-generation ceiling** from physical (or cgroup) memory; the process can still sit idle at **tens of MiB RSS**. Cap flags change when OOM/GC pressure starts, not the empty-process floor.

| Posture | Expected idle RSS (single process) | What drives it | Confidence |
| --- | --- | --- | --- |
| **(a) Untuned industry-default Node** | **~40–120+ MiB** idle for “hello / small service”; **hundreds of MiB–multi‑GiB** only if the app loads heavy frameworks, keeps large caches, or forks **N cluster workers** (≈ N × per-process RSS) | Empty runtime + loaded modules + any workers; heap *limit* often **~0.5–4 GiB** depending on host/cgroup | Empty/minimal HTTP floor **High (Empirical)**; upper “typical app” band **Inference (Medium)** — vendors do not publish idle RSS for frameworks |
| **(b) Aggressively memory-optimized Node/TS** | **~35–80 MiB** idle for a slim single-process HTTP service (stdlib or tiny deps); container/cgroup floor still must leave headroom above peak, not just idle | One process, no cluster-by-default, no prod source maps, small dependency graph, optional `--max-old-space-size` for **cap** (not for lowering idle) | Floor **High (Empirical)** on this host; “slim real service” **Inference (Medium)** |

**Bottom line:** Optimizing for memory mainly avoids **multiplicative process count** and **application/retained heap**, not a magic runtime that idles at a few MiB. Expect roughly **the same empty-Node floor (~35–40 MiB on this host)** whether or not you set `--max-old-space-size`; savings vs “defaults” show up as **not forking N workers**, **not retaining large heaps**, and **sizing the cgroup to measured peak + margin** rather than trusting a multi‑GiB heap limit.

---

## What “idle” means (keep these separate)

| Mode | Definition used here | Idle RSS from primary vendors? |
| --- | --- | --- |
| **Empty process** | Runtime started; no HTTP listen; eval/`-e` exits or idles with no app graph | **Absent** for Node/Deno/Bun as a published floor; **Empirical** below for Node on this host |
| **Minimal HTTP** | `node:http` (or equivalent) listening; no framework | Same: **Absent** officially; **Empirical** for Node |
| **Framework hello-world** | Express/Fastify/Nest/Next/etc. booted | **Absent** in first-party runtime docs (framework docs rarely publish idle RSS either) |
| **Production “idle” service** | App loaded, pools/clients constructed, waiting for traffic | Dominated by **your** retained objects — measure; do not use empty-process RSS as capacity planning |

Browser Chromium is a different process model (browser + renderer(s) + GPU, …) and is not comparable to a single Node isolate — **out of scope**.

---

## Heap limit vs RSS (do not conflate)

| Metric | What it is | Owner |
| --- | --- | --- |
| **V8 old-generation / heap size limit** | Hard ceiling for the managed JS heap; approaching it increases GC; exceeding it can fatal OOM | V8 `ResourceConstraints` / `--max-old-space-size`; Node wires defaults via `ConfigureDefaults` |
| **`heapTotal` / `heapUsed`** | Current V8 heap reservation / live JS heap | [`process.memoryUsage()`](https://nodejs.org/api/process.html#processmemoryusage) |
| **`rss` (Resident Set Size)** | Bytes of the process in RAM (JS + C++ + code + native allocs) | Same API: *“amount of space occupied in the main memory device … including all C++ and JavaScript objects and code”* ([process.memoryUsage](https://nodejs.org/api/process.html#processmemoryusage)) |

Node’s own example output shows `rss` in the ~5 MiB range in the doc snippet — that is **illustrative sample output**, not a stated product floor ([process.memoryUsage](https://nodejs.org/api/process.html#processmemoryusage)).

**Empirical (this host, 2026-08-21):** with default heap limit **4144 MiB**, empty `node -e` reported **`rss ≈ 37.5–38.8 MiB`** and `heapUsed ≈ 3.4–3.8 MiB`. Setting `--max-old-space-size=64` left RSS essentially unchanged (~38 MiB) while cutting `heap_size_limit` to **176 MiB**. So: **cap ≠ idle footprint**.

---

## Node.js + V8: how the default heap limit is chosen

### Node passes “available memory” into V8

In `SetIsolateCreateParamsForNode`, Node reads libuv constrained memory (cgroup/container when present) and total memory, takes the minimum when constrained, and if the old-generation max was not already set, calls V8 `ConfigureDefaults(total_memory, 0)`:

```cpp
// node/src/api/environment.cc (main)
const uint64_t constrained_memory = uv_get_constrained_memory();
const uint64_t total_memory = constrained_memory > 0 ?
    std::min(uv_get_total_memory(), constrained_memory) :
    uv_get_total_memory();
if (total_memory > 0 &&
    params->constraints.max_old_generation_size_in_bytes() == 0) {
  // V8 browser defaults (700MB / 1.4GB) are overridden:
  params->constraints.ConfigureDefaults(total_memory, 0);
}
```

Source: [nodejs/node `src/api/environment.cc`](https://github.com/nodejs/node/blob/main/src/api/environment.cc). Historical intent (use cgroups, not only host RAM): [nodejs/node#27508](https://github.com/nodejs/node/pull/27508).

**Operator API:** [`process.constrainedMemory()`](https://nodejs.org/api/process.html#processconstrainedmemory) — bytes available under OS/cgroup limits, or `0` if unknown/unconstrained (**Stable** as of recent Node docs).

**Empirical (this host):** `os.totalmem() = 16 GiB`, `process.constrainedMemory() = 0` (no cgroup limit), default `heap_size_limit ≈ 4144 MiB`.

### V8 old-generation heuristic (64-bit)

`Heap::OldGenerationSizeFromPhysicalMemory` (V8 `main`):

- On 64-bit (non-Android): `old_generation = physical_memory / 2`, then clamp to `[kDefaultMinHeapSize, kDefaultMaxHeapSize]`.
- Constants in `heap.h`: **min 256 MiB**, **max 4 GiB** on 64-bit hosts.

Sources: [v8 `src/heap/heap.cc` — `OldGenerationSizeFromPhysicalMemory`](https://github.com/v8/v8/blob/main/src/heap/heap.cc), [v8 `src/heap/heap.h` — `kDefaultMinHeapSize` / `kDefaultMaxHeapSize`](https://github.com/v8/v8/blob/main/src/heap/heap.h).

With pointer compression enabled, allocator also imposes a **~4 GiB cage** on the compressible heap ([V8 pointer compression](https://v8.dev/blog/pointer-compression); Node options code references a 4 GiB pointer-compression heap when computing percentages — [nodejs `src/node_options.cc`](https://github.com/nodejs/node/blob/main/src/node_options.cc)).

**Worked example (High):** unconstrained 16 GiB host → V8 would want `16/2 = 8 GiB`, clamped to **4 GiB** old gen → matches observed ~**4144 MiB** `heap_size_limit` (limit includes young gen bookkeeping; do not expect exact 4096).

**Container example (High on heuristic, Medium on exact MiB):** cgroup limit 512 MiB → `ConfigureDefaults(512 MiB)` → old gen ≈ `max(256 MiB, 512/2)` = **256 MiB** floor path, or 50%-class behavior called out in Red Hat’s Node 20 container article as *documentation of observed Node behavior* — prefer measuring `v8.getHeapStatistics().heap_size_limit` inside the real cgroup; Node’s own wiring is the source of truth ([environment.cc](https://github.com/nodejs/node/blob/main/src/api/environment.cc)).

Young / semi-space defaults also scale with the memory limit; Node documents that on 64-bit with a **512 MiB** limit, max semi-space may default to **1 MiB**, and for limits ≤ **2 GiB** stays **&lt; 16 MiB** ([CLI `--max-semi-space-size`](https://nodejs.org/api/cli.html)).

---

## Flags and related knobs

| Knob | Effect on **limit** | Effect on **idle RSS** | Source |
| --- | --- | --- | --- |
| `--max-old-space-size=SIZE` (MiB) | Caps V8 old space; GC intensifies near limit | **Negligible** on empty process (**Empirical**) | [CLI](https://nodejs.org/api/cli.html) |
| `--max-old-space-size-percentage=P` | Old space = P% of available (constrained if set) memory | Same as above | [CLI](https://nodejs.org/api/cli.html), [node_options.cc](https://github.com/nodejs/node/blob/main/src/node_options.cc) |
| `--max-semi-space-size` / `--max-heap-size` | Young-gen / overall heap tuning | Throughput vs memory trade-off under load; not an idle-RSS silver bullet | [CLI](https://nodejs.org/api/cli.html) |
| `--enable-source-maps` | Caches source maps for stacks; docs warn of **latency** when `Error.stack` is hit | Idle empty process: **no material RSS change** on this host (**Empirical**); real TS apps can retain map data under load (**Inference**) | [CLI](https://nodejs.org/api/cli.html) |
| `UV_THREADPOOL_SIZE` | Libuv pool size (default **4**) | More threads → more native stacks/TLS; usually small vs heap at idle | [CLI / env docs history](https://github.com/nodejs/node/commit/449549bc4fa642745291e5011fe52b876453eff8) |
| `cluster.fork()` | **Separate processes** | Idle RSS **scales ~linearly with worker count** | [cluster](https://nodejs.org/api/cluster.html): “workers are all separate processes” |
| `worker_threads` | Extra isolates in-process; optional `resourceLimits.maxOldGenerationSizeMb` | Extra heaps/stacks inside one RSS; still not free | [worker_threads](https://nodejs.org/api/worker_threads.html) |

---

## Industry defaults (platform / PaaS heuristics)

These are **container/function memory allotments**, not Node idle RSS. They shape what V8 sees via cgroup/`constrainedMemory` when the platform enforces limits.

| Platform | Default memory allotment | Relevance | Source |
| --- | --- | --- | --- |
| **AWS Lambda** | **128 MB** default (min); up to 10,240 MB | Smallest common “industry default” envelope; AWS recommends 128 MB only for simple functions | [Configure Lambda memory](https://docs.aws.amazon.com/lambda/latest/dg/configuration-memory.html) |
| **Cloud Run (services)** | **512 MiB** per instance (functions: **256 MiB**) | Common container default; executable must be loaded into that budget | [Cloud Run memory limits](https://cloud.google.com/run/docs/configuring/services/memory-limits) |
| **Untuned Node on a large VM** | No cgroup → heap limit often **up to ~4 GiB** old gen | Easy to confuse “allowed to grow” with “already using” | V8/Node sources above |

**Inference (Medium):** “Industry default Node in prod” usually means **one process per container**, **no `--max-old-space-size`**, heap auto-sized from cgroup or host, and operators sizing the **container** to 256 MiB–2 GiB based on platform defaults / habit — not because Node documents an idle RSS in that range.

---

## Memory-optimized posture (what actually reduces footprint)

| Lever | Realistic effect | Evidence class |
| --- | --- | --- |
| **Single process** (avoid `cluster` sized to `os.availableParallelism()`) | Largest structural win: N workers ≈ N × empty/app RSS | **High** ([cluster](https://nodejs.org/api/cluster.html)) |
| **Small dependency / framework surface** | Idle RSS rises with loaded code and retained globals; stdlib HTTP stays near empty-process floor | Floor **High (Empirical)**; framework delta **Absent** as vendor RSS → measure your app |
| **Cap `--max-old-space-size` below cgroup** | Prevents V8 from trying to grow into OOM-kill territory; **does not** shrink idle empty RSS | **High** (CLI + Empirical) |
| **Honor cgroup** (Node 18.15+ / 19.6+ `constrainedMemory`; long-standing `ConfigureDefaults` path) | Correct heap *limit* in containers | **High** |
| **No `--enable-source-maps` in prod** | Avoids map cache / stack cost under errors | Latency **High** (docs); RSS savings **Inference** |
| **Slim native addons / avoid leaked buffers** | `external` / `arrayBuffers` sit outside “JS heap” intuition but in RSS | **High** ([memoryUsage](https://nodejs.org/api/process.html#processmemoryusage)) |
| **Bun / Deno as “slimmer runtime”** | First-party docs expose measurement APIs; **do not publish idle RSS floors**. Bun documents footprint helpers and heap tooling, not a guaranteed smaller idle than Node | [Deno.memoryUsage](https://docs.deno.com/api/deno/~/Deno.MemoryUsage), [Bun unsafe.memoryFootprint](https://bun.com/reference/bun/unsafe/memoryFootprint), [Bun benchmarking / memory](https://bun.com/docs/project/benchmarking). **Not measured on this research host** (runtimes not installed; installer download blocked in this environment) |

**What is *not* realistic:** expecting single-digit MiB idle for a full Node service comparable to Redis’s published ~3 MB empty instance ([Redis FAQ](https://redis.io/docs/latest/develop/get-started/faq/) — contrast only). Node’s runtime + V8 baseline is larger; primary sources do not claim otherwise.

---

## Empirical measurements (this research host)

**Host:** macOS Darwin arm64, **16 GiB** RAM, **Node.js v22.20.0** (nvm).  
**Label:** Empirical on this host — not a vendor claim; Linux containers, musl/glibc, and CPU arch can shift RSS.

| Workload | `rss` (MiB) | `heapUsed` (MiB) | `heap_size_limit` (MiB) | Notes |
| --- | --- | --- | --- |
| Empty `node -e` (5 runs) | **37.5–37.6** | ~3.4 | **4144** | Default untuned |
| Empty + `--max-old-space-size=64` | **~38** | ~3.4 | **176** | Cap does not lower idle RSS |
| Empty + `--max-old-space-size=256` | **~38** | ~3.4 | (raised vs 64) | Same idle story |
| Minimal `http.createServer` after `listen` | **~40.5** | ~4.3 | 4144 | Stdlib only |
| Empty + `--enable-source-maps` | **~37.6** | ~3.4 | 4144 | No idle win/loss here |
| `/usr/bin/time -l` max RSS for `node -e '0'` | **~37.7** (39567360 bytes) | — | — | Confirms `process.memoryUsage().rss` order of magnitude |

**Deno / Bun:** not installed here; official docs provide APIs to measure, not published idle RSS tables (**Absent**).

---

## Deno and Bun (primary-source status)

| Runtime | Idle RSS published? | What they do publish |
| --- | --- | --- |
| **Deno** | **Absent** | [`Deno.memoryUsage()`](https://docs.deno.com/api/deno/~/Deno.MemoryUsage) (`rss`, `heapTotal`, `heapUsed`, `external`); heap-snapshot example docs |
| **Bun** | **Absent** as a product floor | [`Bun.unsafe.memoryFootprint()`](https://bun.com/reference/bun/unsafe/memoryFootprint); JS vs native heap measurement notes in [benchmarking](https://bun.com/docs/project/benchmarking). Issue threads may discuss RSS for specific apps — treat as non-normative unless promoted into docs |

Do **not** take third-party “Bun uses X MB idle” blog numbers as answers.

---

## Operator answer (short)

1. **Untuned Node default (a):** plan idle **~40–120+ MiB RSS per process** for a small service, with **heap limit often 0.25–4 GiB** depending on cgroup/host. Multi-worker cluster multiplies that. Confidence: floor **High**; “typical framework app” **Inference (Medium)**.
2. **Aggressively memory-optimized Node/TS (b):** same empty floor (**~35–40 MiB** on this class of host), target **~40–80 MiB** idle for a slim single-process service, set **`--max-old-space-size`** (or percentage) to something **below** the cgroup limit for safety, and size the container from **measured peak**, not from the heap ceiling. Confidence: floor **High (Empirical)**; slim-service band **Inference (Medium)**.
3. **Always measure** `process.memoryUsage().rss` / cgroup `memory.current` under your real boot path. Vendors do not publish a universal idle RSS for “a Node API.”

---

## Sources

- [Node.js CLI — `--max-old-space-size`, `--max-semi-space-size`, `--max-old-space-size-percentage`, `--enable-source-maps`](https://nodejs.org/api/cli.html)
- [Node.js `process.memoryUsage()` / `constrainedMemory()`](https://nodejs.org/api/process.html)
- [Node.js `cluster`](https://nodejs.org/api/cluster.html)
- [Node.js `worker_threads` resourceLimits](https://nodejs.org/api/worker_threads.html)
- [nodejs/node `src/api/environment.cc` — `SetIsolateCreateParamsForNode`](https://github.com/nodejs/node/blob/main/src/api/environment.cc)
- [nodejs/node `src/node_options.cc` — percentage + constrained memory](https://github.com/nodejs/node/blob/main/src/node_options.cc)
- [nodejs/node#27508 — cgroup memory for heap defaults](https://github.com/nodejs/node/pull/27508)
- [V8 `OldGenerationSizeFromPhysicalMemory` / heap defaults](https://github.com/v8/v8/blob/main/src/heap/heap.cc), [heap.h constants](https://github.com/v8/v8/blob/main/src/heap/heap.h)
- [V8 pointer compression (4 GB cage context)](https://v8.dev/blog/pointer-compression)
- [AWS Lambda configure memory (128 MB default)](https://docs.aws.amazon.com/lambda/latest/dg/configuration-memory.html)
- [Google Cloud Run memory limits (512 MiB default service)](https://cloud.google.com/run/docs/configuring/services/memory-limits)
- [Deno.MemoryUsage](https://docs.deno.com/api/deno/~/Deno.MemoryUsage)
- [Bun `unsafe.memoryFootprint`](https://bun.com/reference/bun/unsafe/memoryFootprint), [Bun benchmarking — memory](https://bun.com/docs/project/benchmarking)
