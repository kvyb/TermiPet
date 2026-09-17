# Pi Colleague Comments

TermiPet can occasionally react to your recent Pi coding work as a colleague at a
neighboring desk. A short, honest remark shows up in the chat panel's **Colleague**
tab instead of a full recap or a review checklist. The feature is
**off by default** and only exists in this build for direct human use.

## Enabling

1. Open the pet chat from the floating toolbar.
2. Switch to the **Colleague** tab.
3. Turn on **Colleague comments**.

The panel shows the exact disclosure text next to the switch, including where the
excerpt goes. Nothing is sent while the switch is off, and turning it off stops
the timer, cancels an automatic request that is already in flight, and suppresses
whatever that request would have delivered. Your pet chat and any colleague
replies you started are not interrupted.

## Defaults

| Behaviour | Default |
| --- | --- |
| Enabled | No (opt-in) |
| Cadence | One randomized global gap of 20-40 minutes, including the first wait after enabling |
| Candidates per cadence | One session, the one with the newest qualifying user activity |
| Session eligibility | Real user text inside the last 3 hours, on the same local calendar day |
| Lifetime limit | At most one automatic comment per Pi session ID, ever (no daily reset) |
| Restart / wake | An overdue due time is pushed a full quiet gap into the future instead of firing immediately |
| Minimum spacing | 10 minutes between automatic attempts, even if a due time was missed |

Nothing happens at launch: the first comment can only arrive one full gap after the
feature is enabled, and every attempt re-reads the current state before spending it.

## Enabling outside the UI

The state file can also be prepared by hand (app must be quit first):

```json
{
  "settings": { "isEnabled": true, "minimumGap": 1200, "maximumGap": 2400 },
  "receipts": {},
  "recentRequests": []
}
```

`recentRequests` is optional and is appended automatically (bounded to 20 entries); older
state files without it still load.

at `~/Library/Application Support/TermiPet/pi-colleague.json`. Delete the file to reset
all receipts and settings. `receipts` is the lifetime dedupe list; removing an entry
from it allows one more automatic comment for that session ID.

## What is sent

Each automatic comment sends exactly two messages to the owner's humanlike model:

- A short system instruction describing the colleague framing ("untrusted context",
  no recap/checklist, `[SKIP]` allowed).
- A bounded excerpt of the active branch of the chosen session: recent user and
  assistant text only, trimmed to the last few lines and a few thousand characters.

Before it leaves the machine, the excerpt passes through a heuristic redactor that
masks recognizable credential shapes (`sk-…`, `ghp_…`, `AKIA…`), key/value forms
(`token=…`, `--token=…`, `client_secret <value>`, `Authorization: Bearer …`),
JWT-looking values, private-key blocks, email addresses, long digit runs,
home-directory paths (`/Users/name` becomes `~`) and very long opaque tokens.
Redacting an already redacted excerpt is a no-op, so retained excerpts are never
mangled further.

Redaction limits, stated plainly: only recognizable shapes are caught. Ordinary
prose, file names, code snippets, and unusual secret formats can still be sent. If
that is not acceptable for a project, leave the feature off.

## API contract

Automatic comments and user replies both use the same owner-run endpoint:

| Item | Value |
| --- | --- |
| Endpoint | `https://api.lessthanthreeai.com/v1/chat/completions` |
| Model | `qwen3.8-27b-humanlike-chat` |
| Authentication | None (no API key, no `Authorization` header is sent) |
| Transport | Streaming SSE, total request/resource deadline 240 seconds, cancellation-aware |
| Sampling | `temperature 0.7`, `top_p 0.8`, `top_k 20`, `min_p 0`, `presence_penalty 1.5`, `repetition_penalty 1.0`, `max_tokens 256`, `chat_template_kwargs.enable_thinking = false` |
| Tagging | Every request carries a unique `x-session-id: internal-termipet-<random>` tag; the echoed response header is validated and the request is rejected on a missing or mismatched echo |

A stream is only accepted when it terminates cleanly with `[DONE]` or
`finish_reason: stop`. Rejected and never shown: `finish_reason: length` or any other
`finish_reason` value (`tool_calls`, `content_filter`, unknown strings), streams that
just stop, nonempty `data:` chunks that are not decodable JSON (so a payload split across two SSE
lines cannot be stitched into a comment; empty heartbeat lines are ignored), server error payloads, empty output, output
that exceeds 2000 characters, and reasoning leakage (`reasoning_content`,
`<thinking>`/`<think>`/`<analysis>` and ChatML `<|im_start|>` markers). Accumulation
stops as soon as any of those conditions is seen, so a broken or hostile stream cannot
grow without bound, and a late result is discarded if the switch was turned off (even if
it was turned on again) or if the Mac slept meanwhile. An exact `[SKIP]` reply is
suppressed (`[SKIP] ...` is treated the same way). Manual replies reuse the same client,
tagging and validation; the tag is never bypassed.

## What stays local

- Project directories, full paths, session file paths and session titles. The panel
  shows a sanitized project basename plus a short session ID, and an optional session
  name if you set one with `/name`. None of that metadata is part of the request.
  The excerpt itself, however, is text from your sessions: it can still mention file
  names, paths and secrets the redactor does not recognize.
- The persisted state file (`pi-colleague.json`) contains only the settings, the next
  due time, the last attempt time, per-session receipts (session ID, status, timestamp)
  and a bounded provenance list of the last 20 internal requests (request ID, whether
  the endpoint echoed the tag, timestamp). No excerpt, prompt, history, response text or
  credential is written to disk, and the provenance list is body-free by construction.
- Comment text you see in the panel lives in memory only, like the pet chat.
- For each thread, the already redacted excerpt lines are also kept in memory (never on
  disk, never rendered as chat bubbles) so a reply can be answered with the original
  context. They are dropped when the app quits or when a thread leaves the 12-thread
  window.
- Nothing is logged: request and response bodies are never printed.

## Lifecycle

- One `flock`-based ownership lock (`pi-colleague.lock`) keeps a second TermiPet launch
  from sending duplicate requests. A second instance shows the same panel with the
  toggle and reply box disabled and an explicit reason; it never changes the shared
  settings and never sends. The owning instance reloads the durable state after
  acquiring the lock, so it never writes a stale pre-lock snapshot over newer
  reservations.
- An unreadable (corrupt) `pi-colleague.json` is treated as fatal for the feature: no
  comments are sent, nothing is overwritten, and the panel says so. Recover by repairing
  or deleting that file and restarting TermiPet. This is deliberate: silently starting
  from an empty receipt list would allow repeat comments.
- The feature runs inside the existing app process; there is no separate daemon.
- Provenance for internal-inference hygiene: every request (automatic comments and the
  replies you type) is sent with its own `internal-termipet-<random>` tag, the echoed
  header is validated, and the sent ID plus the verification outcome (`verified`,
  `tagMissing`, `tagMismatch`, `httpStatus`, `failed`, `cancelled`) is appended to that
  bounded local list. Nothing about the conversation is recorded.
- The lifetime receipt is written **before** the API call. If that write fails, nothing
  is sent (fail closed) and the setting change is reverted. A call that fails or is
  cancelled still consumes that session ID, by design: failed calls are never retried
  and cannot produce a retry storm.
- Scans are bounded (a 16 KiB head plus a 512 KiB tail per candidate file, see above) and
  only happen when a cadence fires, never per second. Whole session files are never read.
  After a failed state write the next scan waits five minutes instead of retrying every
  tick. The scan itself runs on the main actor (a few bounded reads, once per 20-40
  minutes, low severity) - it is deliberately not backgrounded to keep the cadence
  deterministic.
- Sleep/wake is observed: waking cancels an automatic request that spanned the sleep and
  pushes an overdue due time a full quiet gap into the future, exactly like a restart.
  The observer is registered only while the cadence timer runs and is removed on quit.
  A delayed timer tick also re-staggers before spending a request, covering the case
  where the timer fires before the wake notification.

## Supported Pi storage

Sessions are read from `~/.pi/agent/sessions/<project>/*.jsonl` only:

- JSONL session files (version 3 format: header line plus `message` entries with
  `id`/`parentId`), walked from the active leaf along the real branch, so text from
  abandoned branches is never used.
- System prompts, thinking blocks, tool calls, tool results, images, compaction and
  branch summaries, extension entries, and injected harness reminders are ignored.
  Session entries carry no message origin metadata (user entries have only
  `role`/`content`/`timestamp`), so synthetic notifications are excluded by their known
  framing: `<system-reminder>` blocks are stripped, user turns that start with
  `<system>`, `<notification`, `<task-notification`, `[System]` or `System reminder:`
  are dropped, and native workflow notifications such as `Workflow child completed: …`,
  `Background task completed: …`, `Workflow completed`, `Subagent finished: …` (also
  with a leading bullet) are dropped as well. Only that framing is matched, so ordinary
  discussion that merely mentions a subagent or a workflow stays user text. This is
  framing-based and therefore best-effort.
- Reads are bounded per call: exactly one 16 KiB head (header) and one 512 KiB tail
  (active branch) per candidate file, once per cadence, even though real sessions reach
  tens of megabytes (11-33 MB observed). No read ever loads a whole session file, and a
  regression test asserts the recorded read sizes on a multi-megabyte fixture. If that
  tail holds no genuine user text - for example when a multi-megabyte tool result
  follows the last user turn - the session is treated as having no recent activity and is
  skipped (fail closed). Nothing is ever reconstructed from outside the bounded window.
- Nested directories (subagent sessions, artifacts) and symlinked files or project
  directories are skipped.
- Session identity and eligibility use the header session ID and the in-file user
  message timestamps, not the file modification time (the modification time is only a
  cheap pre-filter). A long session that was resumed today is eligible on the resumed
  activity.
- If the active branch cannot be walked back to its root because only a bounded tail was
  read, the excerpt is marked as a partial view rather than being presented as full
  context.

## Replying

Replies stay inside the source session's thread: the request carries the thread's
retained redacted excerpt, that thread's recent messages (at most eight messages and
about 4000 characters), the same colleague system prompt, and no pet personality text.
The thread is capped at twelve messages, and comments from different sessions are never
merged into one conversation. The panel labels the reply target explicitly and keeps it
while you type: a comment from a different session never silently moves your draft, and
selecting a thread is what clears its unread dot. Reply text is passed through the same
redactor.

## Known limits

- Heuristic redaction (see above) is not a guarantee.
- Framing-based filtering of synthetic notifications is best-effort: a notification whose
  framing differs from the known markers can still be read as user text.
- Sessions whose last user turn is buried under a multi-megabyte tool result inside the
  512 KiB tail are skipped rather than guessed at (fail closed).
- A failed or cancelled automatic call consumes the session ID permanently.
- Only the selected thread is marked read: unread dots for other sessions stay until you
  actually open them.
- Replying is unavailable in a non-owning instance and while the state file is corrupt.
- Conversation threads are in memory: quitting TermiPet clears the panel, while the
  per-session receipts and schedule survive in `pi-colleague.json`.
- The app must be running for a cadence to fire.
- Requires macOS 13+, same as the app.

## Tests

Focused synthetic tests live in `Source/Tests/TermiPetTests/` (`PiSessionScannerTests`,
`PiColleaguePrivacyTests`, `PiColleagueResponseContractTests`,
`PiColleagueSchedulingTests`, `PiColleagueStateTests`, `PiColleagueServiceTests`,
`PiColleagueControllerTests`). They use generated fixture files and a stubbed transport
only: no live API calls, no real Pi sessions, no browser or app launch.

```bash
cd Source
swift test -j 2 --filter PiColleague
swift test -j 2
```
