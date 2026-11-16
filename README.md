# openrouter-usage

Widget-bar meter for the free-model daily request quota of the active OpenRouter key.

## What it shows

One widget, `openrouter-usage/usage`, in Tern's widget bar:

- Bar style (default): a fill for the used fraction plus `8/50 · 16%`.
- Text style: the same `8/50 · 16%` string with no fill.
- Tooltip: used, limit and remaining for today.

Data comes from `GET https://openrouter.ai/api/v1/key` with `Authorization: Bearer <key>`. The plugin reads only `data.free_model_daily_requests.{used,limit,remaining}`. The top-level `use`/`limit` fields describe the paid account balance, so they are not used.

Counters must be finite, nonnegative integers, and the limit must be positive. A missing `used` is derived as `limit - remaining`, and a missing `remaining` as `limit - used`. When the nested quota object is absent or invalid, the widget shows `no free quota` rather than zero, and the paid `use`/`limit` fields never fill in for it. When `used` exceeds `limit`, both exact counts still print and the bar clamps to full.

## Reset semantics

`free_model_daily_requests` counts reset at 00:00 UTC. The plugin polls every 5 minutes and on demand; it does not track the clock itself, so a just-passed midnight appears at the next poll.

## Install

Copy or link the package directory into Tern's plugin directory.

```sh
tern plugin dir                                  # where packages live
tern plugin install https://github.com/anagnorisis2peripeteia/tern-openrouter-free-requests
tern plugin list                                 # openrouter-usage ... ready
```

`tern plugin install` copies the package, so re-run it with `--force` after edits. To edit in place instead:

```sh
tern plugin link /path/to/tern-openrouter-free-requests
tern plugin reload openrouter-usage
```

## Place the widget

1. Open the command palette.
2. Run **Edit widgets…** (widget bar).
3. Add `openrouter-usage/usage`.
4. Pick **bar** for the fill, or **text** for the counts alone.

## Set the key

Run **Set OpenRouter API key** from the palette, or click the widget while it reads `no key`. Type the key (`sk-or-v1-…`) and press Return. The value is stored through `tern.secrets`, which keeps it in the system keychain under account `plugin.openrouter-usage.key`. Headless sessions keep it in memory only.

Tern's prompt is a plain one-line field, **not password-masked**: the key is visible in the field while you type, and it appears in that field's history while the prompt is open. Paste it from the clipboard if you want the shortest visible window. Nothing else caches the key: `tern.kv`, environment variables and files are never read for it.

## Commands

| Palette entry | Action name | Effect |
| --- | --- | --- |
| Refresh OpenRouter usage now | `plugin.openrouter-usage.refresh` | Fetch once, immediately |
| Set OpenRouter API key | `plugin.openrouter-usage.set-key` | Prompt for the key, store it, then fetch |

## Status labels

| Label | Meaning |
| --- | --- |
| `loading` | First fetch has not returned yet |
| `no key` | No key in the keychain; run **Set OpenRouter API key** |
| `no free quota` | Response lacked a valid `free_model_daily_requests` object |
| `bad key` | HTTP 401; the stored key was rejected |
| `bad JSON` | Body did not decode as an object |
| `timeout` | Request exceeded 10 s |
| `fetch failed` | Connection, TLS or host failure |
| `http N` | Any other HTTP status |

An invalid or failed response clears the cached counters instead of showing stale numbers, so a label always reflects the most recent completed fetch.

## Files

- `plugin.toml` — manifest: id, name, window entry `window.luau`, style sheet.
- `window.luau` — window half: widget registration, commands, fetch loop.
- `openrouter-usage.css` — tabular figures for the widget's counts, so the digits of `8/50 · 16%` keep their width as the numbers change.
