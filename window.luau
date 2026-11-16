-- OpenRouter free-model daily request usage, as a widget-bar widget.
--
-- Data source: GET https://openrouter.ai/api/v1/key with the plugin's
-- OpenRouter API key in `Authorization: Bearer <key>`. The key record exposes
-- `data.free_model_daily_requests = { used, limit, remaining }`; those counters
-- reset at 00:00 UTC. Only that nested object is read: the top-level `use` and
-- `limit` describe the paid account balance, so they are never a fallback.
--
-- Cached state lives in upvalues. `render` is a pure formatter that only reads
-- them and never calls `tern.chrome.refresh()`; every timer, fetch and command
-- path calls `refresh()` itself.

local API_URL = "https://openrouter.ai/api/v1/key"
local POLL_MS = 300_000 -- 5 minutes; the quota resets daily at UTC midnight.
local SECRET_NAME = "key"

-- Cached render state. Counters are valid only while `ready` is true.
local used: number? = nil
local limit: number? = nil
local remaining: number? = nil
local ready = false
local status_text: string? = nil -- short safe label when `ready` is false
local timer_armed = false
local in_flight = false

-- Forward declarations so callbacks see the later locals, not globals.
local poll_with_key
local tick
local schedule_tick

-- ---------- parsing ----------

-- Finite, nonnegative integer, as the usage counters are; nil otherwise.
local function as_count(n): number?
	if typeof(n) ~= "number" then
		return nil
	end
	if n ~= n or n < 0 or n == math.huge or n == -math.huge then
		return nil
	end
	if n % 1 ~= 0 then
		return nil
	end
	return n
end

local function clear_cache()
	used = nil
	limit = nil
	remaining = nil
	ready = false
end

local function apply_body(body: string)
	local ok, decoded = pcall(tern.json.decode, body)
	if not ok or typeof(decoded) ~= "table" then
		clear_cache()
		status_text = "bad JSON"
		return
	end

	local source = decoded
	if typeof(decoded.data) == "table" then
		source = decoded.data
	end

	local quota = source.free_model_daily_requests
	if typeof(quota) ~= "table" then
		clear_cache()
		status_text = "no free quota"
		return
	end

	local n_used = as_count(quota.used)
	local n_limit = as_count(quota.limit)
	local n_remaining = as_count(quota.remaining)

	if n_limit == nil or (n_limit :: number) <= 0 then
		clear_cache()
		status_text = "no free quota"
		return
	end

	-- Fill whichever counter the response left out from the other two.
	if n_used == nil then
		if n_remaining == nil then
			clear_cache()
			status_text = "no free quota"
			return
		end
		n_used = (n_limit :: number) - (n_remaining :: number)
		if n_used < 0 then
			n_used = 0
		end
	elseif n_remaining == nil then
		n_remaining = (n_limit :: number) - (n_used :: number)
		if n_remaining < 0 then
			n_remaining = 0
		end
	end

	used = n_used
	limit = n_limit
	remaining = n_remaining
	ready = true
	status_text = nil
end

-- ---------- fetching ----------

local function on_fetch(result, _cx)
	in_flight = false
	if result.error ~= nil then
		clear_cache()
		status_text = if result.timed_out then "timeout" else "fetch failed"
	elseif result.status == 200 then
		apply_body(result.body)
	else
		clear_cache()
		if result.status == 401 then
			status_text = "bad key"
		else
			status_text = "http " .. tostring(result.status)
		end
	end
	tern.chrome.refresh()
	schedule_tick(POLL_MS)
end

function poll_with_key()
	if in_flight then
		return
	end
	in_flight = true
	tern.secrets.get(SECRET_NAME):next(function(value, err, _cx)
		if err ~= nil then
			in_flight = false
			clear_cache()
			status_text = "no key"
			tern.chrome.refresh()
			return
		end
		if typeof(value) ~= "string" or (value :: string) == "" then
			in_flight = false
			clear_cache()
			status_text = "no key"
			tern.chrome.refresh()
			return
		end
		tern.fetch(API_URL, {
			headers = { Authorization = "Bearer " .. (value :: string), Accept = "application/json" },
			timeout_ms = 10_000,
		}, on_fetch)
	end)
end

function tick(_cx)
	timer_armed = false
	poll_with_key()
end

schedule_tick = function(delay_ms: number)
	if not timer_armed then
		timer_armed = true
		tern.timer(delay_ms, tick)
	end
end

-- ---------- widget ----------

local function clamp01(n: number): number
	if n < 0 then
		return 0
	end
	if n > 1 then
		return 1
	end
	return n
end

-- "8/50 · 16%" from validated integer counters.
local function counts_text(n_used: number, n_limit: number): string
	local pct = if n_limit > 0 then (n_used / n_limit) * 100 else 0
	return string.format("%.0f/%.0f · %.0f%%", n_used, n_limit, pct)
end

local function render(_pane)
	if not ready or used == nil or limit == nil then
		local label = if status_text ~= nil then status_text :: string else "loading"
		local note = if status_text ~= nil then "OpenRouter usage: " .. label else "OpenRouter usage: loading"
		local command = if label == "no key" or label == "bad key"
			then "plugin.openrouter-usage.set-key"
			else "plugin.openrouter-usage.refresh"
		return {
			text = label,
			tone = if status_text ~= nil then "muted" else "accent",
			title = note,
			command = command,
		}
	end

	local n_used = used :: number
	local n_limit = limit :: number
	local frac = clamp01(if n_limit > 0 then n_used / n_limit else 0)
	local tone = if frac >= 0.9 then "error" elseif frac >= 0.7 then "warn" else "accent"
	local n_remaining = if remaining ~= nil then remaining :: number else n_limit - n_used

	return {
		text = counts_text(n_used, n_limit),
		tone = tone,
		title = string.format(
			"OpenRouter free models: %.0f of %.0f used, %.0f left today (UTC reset)",
			n_used,
			n_limit,
			n_remaining
		),
		value = frac,
		command = "plugin.openrouter-usage.refresh",
	}
end

tern.chrome.widget("usage", {
	name = "OpenRouter usage",
	description = "Free-model daily requests used today on the active OpenRouter key.",
	icon = "gauge",
	styles = { "bar", "text" },
	render = render,
})

-- ---------- commands ----------

tern.command({
	id = "refresh",
	title = "Refresh OpenRouter usage now",
	icon = "repeat",
	run = function(_cx)
		poll_with_key()
	end,
})

tern.command({
	id = "set-key",
	title = "Set OpenRouter API key",
	icon = "key",
	run = function(cx)
		-- Tern's prompt is a plain one-field line editor: it is not password-masked.
		cx:prompt({
			placeholder = "sk-or-v1-...",
			icon = "key",
			action = "save",
		}):next(function(value, _err, pcx)
			if typeof(value) ~= "string" or (value :: string) == "" then
				if pcx then
					pcx:toast("warn", "OpenRouter key not saved.")
				end
				return
			end
			tern.secrets.set(SECRET_NAME, value :: string):next(function(_nil_value, set_err, scx)
				if set_err ~= nil then
					if scx then
						scx:toast("error", "OpenRouter key not saved.")
					end
					return
				end
				if scx then
					scx:toast("success", "OpenRouter key saved.")
				end
				poll_with_key()
			end)
		end)
	end,
})

-- ---------- start ----------

schedule_tick(0)
