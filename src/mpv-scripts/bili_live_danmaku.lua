local utils = require("mp.utils")
local opts = require("mp.options")
local msg = require("mp.msg")

local o = {
    enabled = true,
    poll_interval = 1.0,
    font_size = 40,
    max_lines = 14,
    duration = 11.0,
    horizontal_span_ratio = 1.0,
    area_ratio = 0.45,
    margin_top = 24,
    line_gap = 8,
    min_interval = 0.25,
    item_margin = 16,
    top_stack_ratio = 0.35,
    top_lane_bias = 4.0,
    merge_tolerance = 0,
    max_screen_danmaku = 0,
    video_seek_reset_threshold = 0.70,
    video_prefill_extra = 1.20,
    video_prefill_max = 260,
    video_prefill_min_elapsed = 0.10,
    video_prefill_startup_advance = 0.35,
    video_prefill_min_progress = 0.00,
    video_emit_batch = 56,
    video_emit_batch_max = 220,
    video_emit_lag_step = 0.08,
    video_emit_lag_boost = 18,
    video_retry_window = 3.0,
    video_retry_max = 600,
    video_retry_batch = 120,
    video_retry_tick_batch = 56,
    video_retry_step = 0.08,
    video_startup_hold = true,
    video_startup_hold_timeout = 4.0,
    show_user = false,
    force_room_id = "",
    perf_log = true,
    perf_log_interval = 5.0,
    perf_slow_ms = 8.0,
    perf_log_to_file = true,
}
opts.read_options(o, "bili_live_danmaku")

local overlay = mp.create_osd_overlay("ass-events")

local active = false
local enabled = o.enabled
local room_short_id = nil
local room_id = nil
local source_mode = "none"
local video_bvid = nil
local video_cid = nil
local video_load_wall_time = nil
local video_first_visible_logged = false
local video_events = {}
local video_next_index = 1
local video_last_time = 0
local video_clock_wall = nil
local video_clock_raw = 0
local video_clock_time = 0
local video_clock_paused = false
local fetch_running = false
local poll_timer = nil
local render_timer = nil
local video_start_hold_active = false
local video_start_hold_prev_pause = nil
local video_start_hold_timer = nil
local comments = {}
local comment_buffer = {}
local line_buffer = {}
local lane_next_time = {}
local lane_tail_cache = {}
local seen = {}
local seen_order = {}
local max_seen = 4000
local curl_ok = true
local font_size = o.font_size
local duration = o.duration
local no_message_polls = 0
local has_message = false
local last_no_message_osd = 0
local last_overlay_data = nil
local anim_time = 0
local anim_last_wall = nil
local render_overlay = nil
local perf_log_path = nil
local add_comment = nil
local restart_danmaku = nil
local recent_text_time = {}
local recent_text_order = {}
local max_recent_text = 4000
local last_osd_w = nil
local last_osd_h = nil
local cached_osd_w = nil
local cached_osd_h = nil
local perf = {
    enabled = false,
    interval = 5.0,
    slow_ms = 8.0,
    next_report_time = 0,
    window_start_time = 0,
    render_count = 0,
    render_total_ms = 0,
    render_max_ms = 0,
    render_slow_count = 0,
    overlay_update_count = 0,
    overlay_skip_count = 0,
    fetch_count = 0,
    fetch_fail_count = 0,
    fetch_total_ms = 0,
    fetch_max_ms = 0,
    parse_count = 0,
    parse_total_ms = 0,
    parse_max_ms = 0,
    parse_added_total = 0,
    lane_drop_count = 0,
    lane_pick_count = 0,
    lane_safe_total = 0,
    lane_min_gap_total = 0,
    lane_used_gap_total = 0,
    lane_used_count = 0,
    lane_top_limit_total = 0,
    lane_lower_pick_count = 0,
    lane_index_total = 0,
    lane_index_norm_total = 0,
    lane_index_count = 0,
    retry_queue_count = 0,
    retry_emit_count = 0,
    retry_expire_count = 0,
    retry_reject_count = 0,
    retry_scan_count = 0,
    retry_defer_count = 0,
    video_emit_count = 0,
    video_emit_defer_count = 0,
    last_comment_count = 0,
    last_line_count = 0,
}

local function clamp(value, minv, maxv)
    if value < minv then
        return minv
    end
    if value > maxv then
        return maxv
    end
    return value
end

local function get_track_width(screen_w)
    local ratio = clamp(tonumber(o.horizontal_span_ratio) or 1.0, 0.12, 1.0)
    return screen_w * ratio
end

local function reload_runtime_options(keep_enabled)
    local prev_enabled = enabled
    opts.read_options(o, "bili_live_danmaku")
    font_size = o.font_size
    duration = o.duration
    if keep_enabled then
        enabled = prev_enabled
        o.enabled = prev_enabled
    else
        enabled = o.enabled
    end
end

local function show_style_status()
    local text = string.format(
        "B站弹幕 大小 %d 速度 %.1fs",
        math.floor(font_size + 0.5),
        duration
    )
    mp.osd_message(text, 2)
end

local function ass_escape(text)
    return text
        :gsub("\\", "\\\\")
        :gsub("{", "\\{")
        :gsub("}", "\\}")
        :gsub("\r", " ")
        :gsub("\n", " ")
end

local function utf8_len(text)
    local _, count = text:gsub("[^\128-\193]", "")
    return count
end

local function html_unescape(text)
    if type(text) ~= "string" then
        return ""
    end
    return text
        :gsub("&amp;", "&")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", "\"")
        :gsub("&#39;", "'")
end

local function detect_video_bvid_and_page()
    local candidates = {
        mp.get_property("path", ""),
        mp.get_property("stream-open-filename", ""),
        mp.get_property("filename", ""),
        mp.get_property("force-media-title", ""),
        mp.get_property("media-title", ""),
    }

    for _, path in ipairs(candidates) do
        if type(path) == "string" and path ~= "" then
            local page = tonumber(path:match("[?&]p=(%d+)")) or 1
            local bvid = path:match("[?&]bvid=(BV[%w]+)")
            if not bvid then
                bvid = path:match("/video/(BV[%w]+)")
            end
            if not bvid then
                bvid = path:match("(BV[%w]+)")
            end
            if bvid and #bvid >= 10 then
                return bvid, page
            end
        end
    end
    return nil, nil
end

local function parse_video_danmaku_xml(xml_text)
    local events = {}
    if type(xml_text) ~= "string" or xml_text == "" then
        return events
    end

    for p, text in xml_text:gmatch('<d p="([^"]+)">(.-)</d>') do
        local stime = tonumber(p:match("^([^,]+)"))
        if stime and stime >= 0 and type(text) == "string" and text ~= "" then
            local cleaned = html_unescape(text)
            cleaned = cleaned:gsub("%s+", " ")
            cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")
            if cleaned ~= "" then
                events[#events + 1] = {
                    time = stime,
                    text = cleaned,
                }
            end
        end
    end

    table.sort(events, function(a, b)
        return a.time < b.time
    end)
    return events
end

local function find_video_event_index(target_time)
    if type(video_events) ~= "table" or #video_events == 0 then
        return 1
    end
    local left = 1
    local right = #video_events
    local ans = #video_events + 1
    while left <= right do
        local mid = math.floor((left + right) / 2)
        if video_events[mid].time >= target_time then
            ans = mid
            right = mid - 1
        else
            left = mid + 1
        end
    end
    if ans < 1 then
        return 1
    end
    return ans
end

local function find_video_event_upper_index(target_time)
    if type(video_events) ~= "table" or #video_events == 0 then
        return 1
    end
    local left = 1
    local right = #video_events
    local ans = #video_events + 1
    while left <= right do
        local mid = math.floor((left + right) / 2)
        if video_events[mid].time > target_time then
            ans = mid
            right = mid - 1
        else
            left = mid + 1
        end
    end
    if ans < 1 then
        return 1
    end
    return ans
end

local function reset_video_active_comments()
    comments = {}
    comment_buffer = {}
    line_buffer = {}
    lane_next_time = {}
    lane_tail_cache = {}
end

local function stop_video_start_hold_timer()
    if video_start_hold_timer then
        video_start_hold_timer:kill()
        video_start_hold_timer = nil
    end
end

local function release_video_start_hold(reason)
    stop_video_start_hold_timer()
    if not video_start_hold_active then
        video_start_hold_prev_pause = nil
        return
    end

    local should_resume = (video_start_hold_prev_pause == false)
    video_start_hold_active = false
    video_start_hold_prev_pause = nil
    if should_resume then
        mp.set_property_bool("pause", false)
    end
    msg.info("bili_live_danmaku video startup hold released reason=" .. tostring(reason))
end

local function begin_video_start_hold()
    stop_video_start_hold_timer()
    video_start_hold_active = false
    video_start_hold_prev_pause = nil

    if not o.video_startup_hold then
        return
    end

    local timeout_sec = clamp(tonumber(o.video_startup_hold_timeout) or 4.0, 0.3, 8.0)
    local paused = mp.get_property_bool("pause", false)
    video_start_hold_prev_pause = paused
    if paused then
        return
    end

    video_start_hold_active = true
    mp.set_property_bool("pause", true)
    mp.osd_message("B站弹幕加载中", 1.2)
    msg.info(string.format("bili_live_danmaku video startup hold begin timeout=%.2fs", timeout_sec))
    video_start_hold_timer = mp.add_timeout(timeout_sec, function()
        release_video_start_hold("timeout")
    end)
end

local function get_video_seek_reset_threshold()
    local threshold = tonumber(o.video_seek_reset_threshold) or 0.70
    return clamp(threshold, 0.30, 5.0)
end

local function prefill_video_comments(raw_time)
    if source_mode ~= "video" or type(video_events) ~= "table" or #video_events == 0 then
        return 0
    end
    local extra = tonumber(o.video_prefill_extra) or 1.20
    extra = clamp(extra, 0, 10)
    local max_add = math.floor(tonumber(o.video_prefill_max) or 260)
    max_add = clamp(max_add, 20, 1500)
    local min_elapsed = clamp(tonumber(o.video_prefill_min_elapsed) or 0.10, 0, 0.80)
    local startup_advance = clamp(tonumber(o.video_prefill_startup_advance) or 0.35, 0, 2.0)
    local min_progress = clamp(tonumber(o.video_prefill_min_progress) or 0.00, 0, 0.85)

    local start_time = math.max(0, raw_time - (duration + extra))
    -- 预填充不仅覆盖历史尾段，也覆盖一小段未来，降低开场空窗
    local future_window = math.max(0.05, startup_advance)
    local end_time = raw_time + future_window
    local first_idx = find_video_event_index(start_time)
    local after_end_idx = find_video_event_upper_index(end_time)
    local last_idx = after_end_idx - 1
    if last_idx < first_idx then
        return 0
    end
    local idx = first_idx
    local window_count = last_idx - first_idx + 1
    local window_span = math.max(0.001, end_time - start_time)
    if window_count > max_add then
        idx = last_idx - max_add + 1
    end
    local added = 0
    while idx <= last_idx do
        local item = video_events[idx]
        if not item or added >= max_add then
            break
        end
        local item_time = tonumber(item.time) or raw_time
        local start_for_render = item_time - startup_advance

        -- 把预填充窗口内的弹幕按时间均匀铺到轨迹上，避免左右两团中间空档
        local ratio = clamp((item_time - start_time) / window_span, 0, 1)
        local progress_min = 0.08
        local progress_max = clamp(math.max(min_progress, 0.70), 0.25, 0.90)
        local target_progress = progress_max - (progress_max - progress_min) * ratio
        local spread_start = raw_time - duration * target_progress
        if start_for_render > spread_start then
            start_for_render = spread_start
        end

        if min_elapsed > 0 and item_time <= raw_time then
            local latest_start = raw_time - min_elapsed
            if start_for_render > latest_start then
                start_for_render = latest_start
            end
        end
        if min_progress > 0 and item_time <= raw_time then
            local progress_start = raw_time - (duration * min_progress)
            if start_for_render > progress_start then
                start_for_render = progress_start
            end
        end
        add_comment("", item.text, start_for_render)
        added = added + 1
        idx = idx + 1
    end
    if added > 0 then
        msg.info(string.format("bili_live_danmaku prefill comments=%d at %.2fs", added, raw_time))
    end
    return added
end

local function align_video_next_index(raw_time)
    local t = tonumber(raw_time) or 0
    local startup_advance = clamp(tonumber(o.video_prefill_startup_advance) or 0.35, 0, 2.0)
    local horizon = math.max(0.05, startup_advance)
    video_next_index = find_video_event_upper_index(t + horizon)
end

local function clear_overlay()
    if last_overlay_data == "" then
        if perf.enabled then
            perf.overlay_skip_count = perf.overlay_skip_count + 1
        end
        return
    end
    overlay.data = ""
    overlay:update()
    last_overlay_data = ""
    if perf.enabled then
        perf.overlay_update_count = perf.overlay_update_count + 1
    end
end

local function reset_anim_clock()
    anim_time = 0
    anim_last_wall = nil
end

local function reset_video_clock()
    video_clock_wall = nil
    video_clock_raw = 0
    video_clock_time = 0
    video_clock_paused = false
end

local function step_video_clock(raw_time)
    local wall = mp.get_time() or 0
    local paused = mp.get_property_bool("pause", false)
    local speed = mp.get_property_number("speed", 1.0) or 1.0
    if speed <= 0 then
        speed = 1.0
    end

    if not video_clock_wall
        or paused ~= video_clock_paused
        or math.abs(raw_time - video_clock_raw) > 0.7
    then
        video_clock_wall = wall
        video_clock_raw = raw_time
        video_clock_time = raw_time
        video_clock_paused = paused
        return video_clock_time
    end

    if paused then
        video_clock_wall = wall
        video_clock_raw = raw_time
        video_clock_time = raw_time
        video_clock_paused = true
        return video_clock_time
    end

    local dt = wall - video_clock_wall
    if dt < 0 then
        dt = 0
    end
    -- 把单次步进封顶，避免调度抖动导致弹幕突然大跳
    dt = math.min(dt, 0.04)

    local predicted = video_clock_time + dt * speed
    local max_ahead = 0.06
    local max_behind = 0.12
    if predicted > raw_time + max_ahead then
        predicted = raw_time + max_ahead
    elseif predicted < raw_time - max_behind then
        predicted = raw_time - max_behind
    end

    video_clock_wall = wall
    video_clock_raw = raw_time
    video_clock_time = predicted
    video_clock_paused = false
    return video_clock_time
end

local function step_anim_clock()
    local wall = mp.get_time() or 0
    if not anim_last_wall then
        anim_last_wall = wall
        return anim_time
    end

    local dt = wall - anim_last_wall
    anim_last_wall = wall
    if dt < 0 then
        dt = 0
    end

    -- 防止时间源瞬时抖动导致单帧大跳步
    dt = math.min(dt, 0.05)
    if not mp.get_property_bool("pause", false) then
        anim_time = anim_time + dt
    end
    return anim_time
end

local function apply_overlay_data(data)
    if last_overlay_data == data then
        if perf.enabled then
            perf.overlay_skip_count = perf.overlay_skip_count + 1
        end
        return
    end
    overlay.data = data
    overlay:update()
    last_overlay_data = data
    if perf.enabled then
        perf.overlay_update_count = perf.overlay_update_count + 1
    end
end

local function init_perf_log()
    perf.enabled = not not o.perf_log
    perf.interval = clamp(tonumber(o.perf_log_interval) or 5.0, 1.0, 60.0)
    perf.slow_ms = clamp(tonumber(o.perf_slow_ms) or 8.0, 2.0, 50.0)
    if not o.perf_log_to_file then
        perf_log_path = nil
        if perf.enabled then
            msg.info("bili_live_danmaku perf log file disabled")
        end
        return
    end

    local config_file = mp.find_config_file("mpv.conf")
    if type(config_file) == "string" and config_file ~= "" then
        local config_dir = config_file:gsub("[/\\][^/\\]+$", "")
        perf_log_path = utils.join_path(config_dir, "bili_live_danmaku_perf.log")
    else
        perf_log_path = "bili_live_danmaku_perf.log"
    end
    if perf.enabled then
        msg.info("bili_live_danmaku perf log path: " .. tostring(perf_log_path))
    end
end

local function write_perf_log(line)
    local stamped = string.format("%s %s", os.date("%Y-%m-%d %H:%M:%S"), line)
    msg.info(stamped)
    if not perf_log_path then
        return
    end
    local fp = io.open(perf_log_path, "a")
    if not fp then
        return
    end
    fp:write(stamped, "\n")
    fp:close()
end

local function reset_perf_window(now_time)
    perf.window_start_time = now_time
    perf.next_report_time = now_time + perf.interval
    perf.render_count = 0
    perf.render_total_ms = 0
    perf.render_max_ms = 0
    perf.render_slow_count = 0
    perf.overlay_update_count = 0
    perf.overlay_skip_count = 0
    perf.fetch_count = 0
    perf.fetch_fail_count = 0
    perf.fetch_total_ms = 0
    perf.fetch_max_ms = 0
    perf.parse_count = 0
    perf.parse_total_ms = 0
    perf.parse_max_ms = 0
    perf.parse_added_total = 0
    perf.lane_drop_count = 0
    perf.lane_pick_count = 0
    perf.lane_safe_total = 0
    perf.lane_min_gap_total = 0
    perf.lane_used_gap_total = 0
    perf.lane_used_count = 0
    perf.lane_top_limit_total = 0
    perf.lane_lower_pick_count = 0
    perf.lane_index_total = 0
    perf.lane_index_norm_total = 0
    perf.lane_index_count = 0
    perf.retry_queue_count = 0
    perf.retry_emit_count = 0
    perf.retry_expire_count = 0
    perf.retry_reject_count = 0
    perf.retry_scan_count = 0
    perf.retry_defer_count = 0
    perf.video_emit_count = 0
    perf.video_emit_defer_count = 0
end

local function maybe_report_perf(now_time)
    if not perf.enabled then
        return
    end
    if perf.next_report_time == 0 then
        reset_perf_window(now_time)
        return
    end
    if now_time < perf.next_report_time then
        return
    end

    local window = math.max(0.001, now_time - perf.window_start_time)
    local render_avg = 0
    if perf.render_count > 0 then
        render_avg = perf.render_total_ms / perf.render_count
    end
    local fetch_avg = 0
    if perf.fetch_count > 0 then
        fetch_avg = perf.fetch_total_ms / perf.fetch_count
    end
    local parse_avg = 0
    if perf.parse_count > 0 then
        parse_avg = perf.parse_total_ms / perf.parse_count
    end
    local safe_lane_avg = 0
    local min_gap_avg = 0
    if perf.lane_pick_count > 0 then
        safe_lane_avg = perf.lane_safe_total / perf.lane_pick_count
        min_gap_avg = perf.lane_min_gap_total / perf.lane_pick_count
    end
    local used_gap_avg = 0
    if perf.lane_used_count > 0 then
        used_gap_avg = perf.lane_used_gap_total / perf.lane_used_count
    end
    local top_limit_avg = 0
    if perf.lane_pick_count > 0 then
        top_limit_avg = perf.lane_top_limit_total / perf.lane_pick_count
    end
    local lane_index_avg = 0
    local lane_index_norm_avg = 0
    if perf.lane_index_count > 0 then
        lane_index_avg = perf.lane_index_total / perf.lane_index_count
        lane_index_norm_avg = perf.lane_index_norm_total / perf.lane_index_count
    end
    local retry_pending = #comment_buffer

    local line = string.format(
        "[bili_live_danmaku][perf] window=%.1fs render=%.2f/%.2fms slow>%0.1fms=%d/%d overlay update/skip=%d/%d comments=%d lines=%d fetch=%.1f/%.1fms fail=%d parse=%.2f/%.2fms added=%d lane_drop=%d lane_pick=%d safe_avg=%.2f min_gap_avg=%.1f used_gap_avg=%.1f top_limit_avg=%.1f lower_pick=%d lane_avg=%.2f lane_norm_avg=%.3f emit e/d=%d/%d retry q/e/x/r=%d/%d/%d/%d scan/defer=%d/%d pending=%d",
        window,
        render_avg,
        perf.render_max_ms,
        perf.slow_ms,
        perf.render_slow_count,
        perf.render_count,
        perf.overlay_update_count,
        perf.overlay_skip_count,
        perf.last_comment_count,
        perf.last_line_count,
        fetch_avg,
        perf.fetch_max_ms,
        perf.fetch_fail_count,
        parse_avg,
        perf.parse_max_ms,
        perf.parse_added_total,
        perf.lane_drop_count,
        perf.lane_pick_count,
        safe_lane_avg,
        min_gap_avg,
        used_gap_avg,
        top_limit_avg,
        perf.lane_lower_pick_count,
        lane_index_avg,
        lane_index_norm_avg,
        perf.video_emit_count,
        perf.video_emit_defer_count,
        perf.retry_queue_count,
        perf.retry_emit_count,
        perf.retry_expire_count,
        perf.retry_reject_count,
        perf.retry_scan_count,
        perf.retry_defer_count,
        retry_pending
    )
    write_perf_log(line)
    reset_perf_window(now_time)
end

local function record_render_perf(start_time, line_count)
    if not perf.enabled then
        return
    end
    local now_time = mp.get_time() or 0
    local elapsed_ms = (now_time - start_time) * 1000
    perf.render_count = perf.render_count + 1
    perf.render_total_ms = perf.render_total_ms + elapsed_ms
    if elapsed_ms > perf.render_max_ms then
        perf.render_max_ms = elapsed_ms
    end
    if elapsed_ms >= perf.slow_ms then
        perf.render_slow_count = perf.render_slow_count + 1
    end
    perf.last_comment_count = #comments
    perf.last_line_count = line_count
    maybe_report_perf(now_time)
end

local function record_fetch_perf(fetch_ms, failed, parse_ms, added_count)
    if not perf.enabled then
        return
    end
    perf.fetch_count = perf.fetch_count + 1
    perf.fetch_total_ms = perf.fetch_total_ms + fetch_ms
    if fetch_ms > perf.fetch_max_ms then
        perf.fetch_max_ms = fetch_ms
    end
    if failed then
        perf.fetch_fail_count = perf.fetch_fail_count + 1
    end
    if parse_ms and parse_ms >= 0 then
        perf.parse_count = perf.parse_count + 1
        perf.parse_total_ms = perf.parse_total_ms + parse_ms
        if parse_ms > perf.parse_max_ms then
            perf.parse_max_ms = parse_ms
        end
    end
    if added_count and added_count > 0 then
        perf.parse_added_total = perf.parse_added_total + added_count
    end
end

local function sync_uosc_toggle_state()
    local state = enabled and "toggle_on" or "toggle_off"
    -- 兼容不同版本 uosc 对 cycle 状态值的解析
    mp.commandv("script-message-to", "uosc", "set", "show_danmaku", state)
    mp.commandv("script-message-to", "uosc", "set", "show_danmaku", enabled and "on" or "off")
end

local function reset_runtime()
    comments = {}
    comment_buffer = {}
    line_buffer = {}
    lane_next_time = {}
    lane_tail_cache = {}
    recent_text_time = {}
    recent_text_order = {}
    seen = {}
    seen_order = {}
    fetch_running = false
    no_message_polls = 0
    has_message = false
    last_no_message_osd = 0
    last_overlay_data = nil
    source_mode = "none"
    video_bvid = nil
    video_cid = nil
    video_load_wall_time = nil
    video_first_visible_logged = false
    video_events = {}
    video_next_index = 1
    video_last_time = 0
    reset_anim_clock()
    reset_video_clock()
    last_osd_w = nil
    last_osd_h = nil
    cached_osd_w = nil
    cached_osd_h = nil
end

local function calc_lane_count_for_height(screen_h)
    local lane_height = font_size + o.line_gap
    local lane_count = math.floor((screen_h * o.area_ratio) / lane_height)
    return math.max(1, math.min(o.max_lines, lane_count))
end

local function remap_comments_for_resize(old_w, old_h, new_w, new_h, now_time)
    if #comments <= 0 then
        lane_next_time = {}
        lane_tail_cache = {}
        return
    end

    local old_lane_count = calc_lane_count_for_height(old_h)
    local new_lane_count = calc_lane_count_for_height(new_h)
    local old_track_default = get_track_width(old_w)
    local new_track_default = get_track_width(new_w)

    local remapped = {}
    local remapped_count = 0
    for i = 1, #comments do
        local item = comments[i]
        if type(item) == "table" then
            local item_start = tonumber(item.start)
            local item_duration = tonumber(item.duration)
            local item_width = tonumber(item.width)
            local item_lane = math.floor(tonumber(item.lane) or 1)
            local item_track_old = tonumber(item.track_w) or old_track_default
            if item_start and item_duration and item_duration > 0 and item_width and item_width > 0 then
                local visible_old = tonumber(item.visible_duration)
                    or (item_duration * ((old_w + item_width) / math.max(1, item_track_old + item_width)))
                local elapsed = now_time - item_start
                if elapsed <= visible_old then
                    local progress_old = clamp(elapsed / item_duration, 0, 1.20)
                    local x_old = old_w - (item_track_old + item_width) * progress_old

                    local item_track_new = new_track_default
                    local progress_new = clamp((new_w - x_old) / math.max(1, item_track_new + item_width), 0, 1.20)
                    local new_start = now_time - progress_new * item_duration

                    local lane_source = clamp(item_lane, 1, old_lane_count)
                    local new_lane = clamp(lane_source, 1, new_lane_count)
                    if old_lane_count > 1 and new_lane_count > 1 and old_lane_count ~= new_lane_count then
                        local lane_ratio = (lane_source - 1) / (old_lane_count - 1)
                        new_lane = math.floor(lane_ratio * (new_lane_count - 1) + 0.5) + 1
                        new_lane = clamp(new_lane, 1, new_lane_count)
                    end

                    item.start = new_start
                    item.track_w = item_track_new
                    item.lane = new_lane
                    item.visible_duration = item_duration
                        * ((new_w + item_width) / math.max(1, item_track_new + item_width))

                    remapped_count = remapped_count + 1
                    remapped[remapped_count] = item
                end
            end
        end
    end

    comments = remapped
    lane_next_time = {}
    lane_tail_cache = {}
    for i = 1, #comments do
        local item = comments[i]
        local lane = tonumber(item and item.lane)
        local start_t = tonumber(item and item.start)
        if lane and start_t then
            local prev = lane_next_time[lane]
            if not prev or start_t > prev then
                lane_next_time[lane] = start_t
            end
            lane_tail_cache[lane] = item
        end
    end
end

local function handle_osd_resize(w, h, video_raw_time, now_time)
    if not w or not h or w <= 0 or h <= 0 then
        return
    end
    if not last_osd_w or not last_osd_h then
        last_osd_w = w
        last_osd_h = h
        return
    end

    if math.abs(w - last_osd_w) < 1 and math.abs(h - last_osd_h) < 1 then
        return
    end

    local old_w = last_osd_w
    local old_h = last_osd_h
    msg.info(string.format(
        "bili_live_danmaku osd resized %.0fx%.0f -> %.0fx%.0f",
        old_w, old_h, w, h
    ))
    last_osd_w = w
    last_osd_h = h

    local t = tonumber(now_time)
    if not t then
        if source_mode == "video" then
            t = tonumber(video_raw_time) or (mp.get_property_number("time-pos", 0) or 0)
        else
            t = anim_time
        end
    end
    remap_comments_for_resize(old_w, old_h, w, h, t)

    if source_mode == "video" then
        video_load_wall_time = mp.get_time() or 0
        video_first_visible_logged = false
    end
end

local function remember_recent_text(text, now_time)
    local tolerance = tonumber(o.merge_tolerance) or 0
    if tolerance <= 0 then
        return true
    end
    if type(text) ~= "string" or text == "" then
        return true
    end
    local key = text
    local last_time = recent_text_time[key]
    if last_time and (now_time - last_time) <= tolerance then
        return false
    end
    recent_text_time[key] = now_time
    recent_text_order[#recent_text_order + 1] = key
    if #recent_text_order > max_recent_text then
        local old = table.remove(recent_text_order, 1)
        if old then
            recent_text_time[old] = nil
        end
    end
    return true
end

local function stop_poll_timer()
    if poll_timer then
        poll_timer:kill()
        poll_timer = nil
    end
end

local function stop_render_timer()
    if render_timer then
        render_timer:kill()
        render_timer = nil
    end
end

local function pick_render_hz()
    return 120
end

local function ensure_render_timer()
    local hz = pick_render_hz()
    local interval = 1 / hz
    local display_fps = mp.get_property_number("display-fps", 0) or 0
    msg.info(string.format("bili_live_danmaku render timer set to %.0fHz display-fps=%.3f", hz, display_fps))
    stop_render_timer()
    render_timer = mp.add_periodic_timer(interval, render_overlay)
    render_timer:stop()
end

local function stop_all()
    active = false
    room_short_id = nil
    room_id = nil
    reset_runtime()
    stop_poll_timer()
    stop_render_timer()
    release_video_start_hold("stop_all")
    clear_overlay()
    sync_uosc_toggle_state()
end

local function remember_seen(id)
    if seen[id] then
        return false
    end
    seen[id] = true
    seen_order[#seen_order + 1] = id
    if #seen_order > max_seen then
        local old = table.remove(seen_order, 1)
        if old then
            seen[old] = nil
        end
    end
    return true
end

local function get_cached_osd_size()
    local w = cached_osd_w
    local h = cached_osd_h
    if not w or w <= 0 or not h or h <= 0 then
        w, h = mp.get_osd_size()
        if not w or w <= 0 then
            w = 1920
        end
        if not h or h <= 0 then
            h = 1080
        end
        cached_osd_w = w
        cached_osd_h = h
    end
    return w, h
end

local function lane_tail_active(item, lane, now_time)
    if type(item) ~= "table" then
        return false
    end
    if tonumber(item.lane) ~= lane then
        return false
    end
    local item_start = tonumber(item.start)
    local item_duration = tonumber(item.duration)
    if not item_start or not item_duration or item_duration <= 0 then
        return false
    end
    return now_time <= (item_start + item_duration)
end

local function latest_lane_item(lane, now_time)
    local cached = lane_tail_cache[lane]
    if lane_tail_active(cached, lane, now_time) then
        return cached
    end

    for i = #comments, 1, -1 do
        local item = comments[i]
        if lane_tail_active(item, lane, now_time) then
            lane_tail_cache[lane] = item
            return item
        end
    end
    lane_tail_cache[lane] = nil
    return nil
end

local function lane_min_gap(tail, new_width, new_duration, now_time, screen_w)
    if not tail then
        return math.huge
    end
    local old_start = tonumber(tail.start)
    local old_duration = tonumber(tail.duration)
    local old_width = tonumber(tail.width)
    if not old_start or not old_duration or old_duration <= 0 or not old_width then
        return -math.huge
    end
    local old_end = old_start + old_duration
    if now_time >= old_end then
        return math.huge
    end

    local new_end = now_time + new_duration
    local check_end = math.min(old_end, new_end)
    local old_speed = (screen_w + old_width) / old_duration
    local new_speed = (screen_w + new_width) / new_duration

    local function gap_at(t)
        return old_speed * (t - old_start) - new_speed * (t - now_time) - old_width
    end

    local gap_now = gap_at(now_time)
    if old_speed >= new_speed then
        return gap_now
    end
    local gap_end = gap_at(check_end)
    if gap_end < gap_now then
        return gap_end
    end
    return gap_now
end

local function calc_dynamic_min_gap(lane_count)
    local base_gap = clamp(tonumber(o.item_margin) or 16, 4, 200)
    if lane_count <= 0 then
        return base_gap
    end
    -- 屏上越拥挤，安全间距越小，但采用更平滑曲线避免阈值变化过激
    local active_per_lane = (#comments) / lane_count
    local ratio = active_per_lane / 4.0
    if ratio < 0 then
        ratio = 0
    elseif ratio > 1 then
        ratio = 1
    end
    local shrink = 0.30 * ratio + 0.10 * ratio * ratio
    local dynamic_gap = math.floor(base_gap * (1.0 - shrink) + 0.5)
    return clamp(dynamic_gap, 6, base_gap)
end

local function lane_balance_penalty(lane, now_time)
    local last_time = lane_next_time[lane]
    if not last_time then
        return 0
    end
    local reuse_window = clamp(duration * 0.16, 0.45, 2.2)
    local age = now_time - last_time
    if age >= reuse_window then
        return 0
    end
    local ratio = (reuse_window - age) / reuse_window
    local penalty_max = clamp((tonumber(o.item_margin) or 16) * 0.45, 2, 12)
    return penalty_max * ratio
end

local function lane_top_penalty(lane)
    local bias = clamp(tonumber(o.top_lane_bias) or 4.0, 0, 30)
    return (lane - 1) * bias
end

local function calc_top_lane_limit(lane_count)
    if lane_count <= 1 then
        return lane_count
    end
    local base_ratio = clamp(tonumber(o.top_stack_ratio) or 0.35, 0.20, 1.00)
    -- 低负载时优先使用顶部轨道，高负载时逐步放开到底部轨道
    local pressure = (#comments) / (lane_count * 10.0)
    pressure = clamp(pressure, 0, 1)
    local ratio = base_ratio + (1.0 - base_ratio) * pressure * pressure * pressure
    local limit = math.floor(lane_count * ratio + 0.5)
    return clamp(limit, 1, lane_count)
end

local function pick_lane_range(start_lane, end_lane, now_time, new_width, new_duration, screen_w, min_gap)
    local best_lane = nil
    local best_gap = 0
    local best_score = math.huge
    local fallback_gap = -math.huge
    local safe_count = 0

    for lane = start_lane, end_lane do
        local tail = latest_lane_item(lane, now_time)
        local gap = lane_min_gap(tail, new_width, new_duration, now_time, screen_w)
        if gap >= min_gap then
            safe_count = safe_count + 1
            local score = gap + lane_balance_penalty(lane, now_time) + lane_top_penalty(lane)
            if not best_lane or score < best_score or (score == best_score and gap < best_gap) then
                best_lane = lane
                best_gap = gap
                best_score = score
            end
        elseif gap > fallback_gap then
            fallback_gap = gap
        end
    end

    return best_lane, best_gap, safe_count, fallback_gap
end

local function pick_lane(now_time, lane_count, new_width, new_duration, screen_w, min_gap)
    local top_limit = calc_top_lane_limit(lane_count)
    local best_lane, best_gap, safe_count, fallback_gap =
        pick_lane_range(1, top_limit, now_time, new_width, new_duration, screen_w, min_gap)
    if best_lane then
        return best_lane, best_gap, safe_count, top_limit
    end

    if top_limit < lane_count then
        local lower_lane, lower_gap, lower_safe, lower_fallback =
            pick_lane_range(top_limit + 1, lane_count, now_time, new_width, new_duration, screen_w, min_gap)
        safe_count = safe_count + lower_safe
        if lower_lane then
            return lower_lane, lower_gap, safe_count, top_limit
        end
        if lower_fallback > fallback_gap then
            fallback_gap = lower_fallback
        end
    end

    return nil, fallback_gap, safe_count, top_limit
end

local function maybe_queue_video_comment(text, start_time, now_time, no_queue)
    if no_queue then
        return false
    end
    if source_mode ~= "video" then
        return false
    end
    if type(text) ~= "string" or text == "" then
        return false
    end
    local retry_window = clamp(tonumber(o.video_retry_window) or 3.0, 0, 8.0)
    if retry_window <= 0 then
        if perf.enabled then
            perf.retry_reject_count = perf.retry_reject_count + 1
        end
        return false
    end
    local retry_max = math.floor(clamp(tonumber(o.video_retry_max) or 600, 0, 5000))
    if retry_max <= 0 or #comment_buffer >= retry_max then
        if perf.enabled then
            perf.retry_reject_count = perf.retry_reject_count + 1
        end
        return false
    end
    local base_time = tonumber(start_time)
    if not base_time then
        if perf.enabled then
            perf.retry_reject_count = perf.retry_reject_count + 1
        end
        return false
    end
    local raw_now = mp.get_property_number("time-pos", now_time) or now_time
    local enqueue_base = raw_now
    if base_time > enqueue_base then
        enqueue_base = base_time
    end
    local deadline = enqueue_base + retry_window
    if deadline <= raw_now then
        if perf.enabled then
            perf.retry_reject_count = perf.retry_reject_count + 1
        end
        return false
    end
    comment_buffer[#comment_buffer + 1] = {
        text = text,
        start = base_time,
        deadline = deadline,
        next_try = raw_now,
    }
    if perf.enabled then
        perf.retry_queue_count = perf.retry_queue_count + 1
    end
    return true
end

add_comment = function(user, text, start_time, no_queue, no_drop_metric)
    if type(text) ~= "string" or text == "" then
        return false
    end

    local merged = text
    if o.show_user and type(user) == "string" and user ~= "" then
        merged = user .. " " .. text
    end
    merged = merged:gsub("%s+", " ")
    merged = merged:gsub("^%s+", ""):gsub("%s+$", "")
    if merged == "" then
        return false
    end

    local now_time = tonumber(start_time) or anim_time
    if not no_queue and not remember_recent_text(merged, now_time) then
        return false
    end

    local max_on_screen = math.floor(tonumber(o.max_screen_danmaku) or 0)
    if max_on_screen > 0 and #comments >= max_on_screen then
        if perf.enabled and not no_drop_metric then
            perf.lane_drop_count = perf.lane_drop_count + 1
        end
        maybe_queue_video_comment(merged, now_time, now_time, no_queue)
        return false
    end

    local w, h = get_cached_osd_size()

    local lane_height = font_size + o.line_gap
    local lane_count = math.floor((h * o.area_ratio) / lane_height)
    lane_count = math.max(1, math.min(o.max_lines, lane_count))

    local width = math.max(font_size * 2, utf8_len(merged) * font_size * 0.95)
    local min_gap = calc_dynamic_min_gap(lane_count)
    local track_w = get_track_width(w)
    local lane, chosen_gap, safe_count, top_limit = pick_lane(now_time, lane_count, width, duration, track_w, min_gap)
    if perf.enabled then
        perf.lane_pick_count = perf.lane_pick_count + 1
        perf.lane_safe_total = perf.lane_safe_total + (safe_count or 0)
        perf.lane_min_gap_total = perf.lane_min_gap_total + min_gap
        perf.lane_top_limit_total = perf.lane_top_limit_total + (top_limit or lane_count)
        if lane and chosen_gap and chosen_gap < math.huge then
            perf.lane_used_count = perf.lane_used_count + 1
            perf.lane_used_gap_total = perf.lane_used_gap_total + chosen_gap
            if top_limit and lane > top_limit then
                perf.lane_lower_pick_count = perf.lane_lower_pick_count + 1
            end
            perf.lane_index_count = perf.lane_index_count + 1
            perf.lane_index_total = perf.lane_index_total + lane
            if lane_count > 1 then
                perf.lane_index_norm_total = perf.lane_index_norm_total + ((lane - 1) / (lane_count - 1))
            end
        end
    end
    if not lane then
        if perf.enabled and not no_drop_metric then
            perf.lane_drop_count = perf.lane_drop_count + 1
        end
        maybe_queue_video_comment(merged, now_time, now_time, no_queue)
        return false
    end

    local item = {
        text = ass_escape(merged),
        start = now_time,
        duration = duration,
        visible_duration = duration * ((w + width) / math.max(1, (track_w + width))),
        lane = lane,
        width = width,
        track_w = track_w,
    }
    comments[#comments + 1] = item
    lane_next_time[lane] = now_time
    lane_tail_cache[lane] = item

    if #comments > 1000 then
        table.remove(comments, 1)
    end
    return true
end

local function calc_video_emit_budget(raw_time)
    local base = math.floor(clamp(tonumber(o.video_emit_batch) or 56, 8, 1200))
    local max_batch = math.floor(clamp(tonumber(o.video_emit_batch_max) or 220, base, 3000))
    local lag_step = clamp(tonumber(o.video_emit_lag_step) or 0.08, 0.02, 1.0)
    local lag_boost = math.floor(clamp(tonumber(o.video_emit_lag_boost) or 18, 0, 200))
    local budget = base

    local item = video_events[video_next_index]
    if type(item) == "table" then
        local lag = raw_time - (tonumber(item.time) or raw_time)
        if lag > 0 and lag_boost > 0 then
            budget = budget + math.floor((lag / lag_step) * lag_boost)
        end
    end
    return math.floor(clamp(budget, base, max_batch))
end

local function calc_retry_tick_budget(raw_time, total)
    local hard_batch = math.floor(clamp(tonumber(o.video_retry_batch) or 120, 20, 1500))
    local base = math.floor(clamp(tonumber(o.video_retry_tick_batch) or 56, 8, hard_batch))
    local budget = base
    if total > base then
        budget = budget + math.floor((total - base) * 0.15)
    end
    if budget > hard_batch then
        budget = hard_batch
    end

    local item = video_events[video_next_index]
    if type(item) == "table" then
        local lag = raw_time - (tonumber(item.time) or raw_time)
        if lag > 0.15 then
            budget = math.floor(math.max(8, budget * 0.65))
        end
    end
    return math.floor(clamp(budget, 8, hard_batch))
end

local function flush_video_comment_buffer(raw_time)
    if source_mode ~= "video" then
        return
    end
    local total = #comment_buffer
    if total <= 0 then
        return
    end

    local batch = calc_retry_tick_budget(raw_time, total)
    local retry_step = clamp(tonumber(o.video_retry_step) or 0.08, 0.02, 1.0)
    local limit = math.min(total, batch)
    local kept = {}
    local kept_count = 0
    if perf.enabled then
        perf.retry_scan_count = perf.retry_scan_count + limit
        if total > limit then
            perf.retry_defer_count = perf.retry_defer_count + (total - limit)
        end
    end

    for i = 1, limit do
        local item = comment_buffer[i]
        if type(item) == "table" and type(item.text) == "string" and item.text ~= "" then
            local deadline = tonumber(item.deadline) or -math.huge
            local next_try = tonumber(item.next_try) or raw_time
            if raw_time <= deadline then
                if raw_time >= next_try then
                    -- 重试成功时从当前时刻上屏，避免旧起点导致刚出现就接近过期
                    local ok = add_comment("", item.text, raw_time, true, true)
                    if not ok then
                        item.next_try = raw_time + retry_step
                        kept_count = kept_count + 1
                        kept[kept_count] = item
                    elseif perf.enabled then
                        perf.retry_emit_count = perf.retry_emit_count + 1
                    end
                else
                    kept_count = kept_count + 1
                    kept[kept_count] = item
                end
            elseif perf.enabled then
                perf.retry_expire_count = perf.retry_expire_count + 1
            end
        end
    end

    for i = limit + 1, total do
        kept_count = kept_count + 1
        kept[kept_count] = comment_buffer[i]
    end
    comment_buffer = kept
end

render_overlay = function()
    if not active then
        if last_overlay_data and last_overlay_data ~= "" then
            clear_overlay()
        end
        return
    end

    local render_start = mp.get_time() or 0
    if not enabled then
        clear_overlay()
        record_render_perf(render_start, 0)
        return
    end

    local w, h = mp.get_osd_size()
    if not w or not h or w <= 0 or h <= 0 then
        record_render_perf(render_start, 0)
        return
    end
    cached_osd_w = w
    cached_osd_h = h

    local now_time = step_anim_clock()
    local raw_time = mp.get_property_number("time-pos", 0) or 0
    if source_mode == "video" then
        now_time = step_video_clock(raw_time)
    end
    handle_osd_resize(w, h, raw_time, now_time)
    if source_mode == "video" then
        if math.abs(raw_time - video_last_time) > get_video_seek_reset_threshold() then
            reset_video_active_comments()
            prefill_video_comments(raw_time)
            align_video_next_index(raw_time)
            video_load_wall_time = mp.get_time() or 0
            video_first_visible_logged = false
        end
        video_last_time = raw_time

        local emit_budget = calc_video_emit_budget(raw_time)
        local emitted = 0
        while video_next_index <= #video_events do
            if emitted >= emit_budget then
                if perf.enabled then
                    perf.video_emit_defer_count = perf.video_emit_defer_count + 1
                end
                break
            end
            local item = video_events[video_next_index]
            if not item or item.time > (raw_time + 0.05) then
                break
            end
            add_comment("", item.text, item.time)
            video_next_index = video_next_index + 1
            emitted = emitted + 1
        end
        if perf.enabled and emitted > 0 then
            perf.video_emit_count = perf.video_emit_count + emitted
        end
        flush_video_comment_buffer(raw_time)
    end
    local lane_height = font_size + o.line_gap
    local lines = line_buffer
    local old_comment_count = #comments
    local old_line_count = #lines
    local kept_count = 0
    local line_count = 0
    local dropped_invalid = 0
    local visible_min_x = nil
    local visible_max_x = nil
    lane_tail_cache = {}
    for i = 1, old_comment_count do
        local item = comments[i]
        if type(item) == "table" then
            local item_start = tonumber(item.start)
            local item_duration = tonumber(item.duration)
            local item_visible_duration = tonumber(item.visible_duration) or item_duration
            local item_text = item.text
            if item_start and item_duration and item_duration > 0
                and item_visible_duration and item_visible_duration > 0
                and type(item_text) == "string" and item_text ~= ""
            then
                local elapsed = now_time - item_start
                if elapsed <= item_visible_duration then
                    kept_count = kept_count + 1
                    comments[kept_count] = item
                    local item_lane = tonumber(item.lane) or 1
                    if item_lane < 1 then
                        item_lane = 1
                    end
                    lane_tail_cache[item_lane] = item
                    if elapsed >= 0 then
                        local progress = elapsed / item_duration
                        local item_width = tonumber(item.width) or (font_size * 2)
                        local item_track_w = tonumber(item.track_w) or get_track_width(w)
                        -- 从右边缘进入，直到整条弹幕完全越过左边缘后才结束
                        -- 始终从右侧外进入，再按压缩后的轨迹长度向左移动
                        local x = w - (item_track_w + item_width) * progress
                        local y = o.margin_top + (item_lane - 1) * lane_height
                        if not visible_min_x or x < visible_min_x then
                            visible_min_x = x
                        end
                        if not visible_max_x or x > visible_max_x then
                            visible_max_x = x
                        end
                        line_count = line_count + 1
                        lines[line_count] = string.format(
                            "{\\an7\\q2\\fs%d\\bord1.6\\blur0.6\\shad0\\alpha&H33&\\1c&HFFFFFF&\\3c&HD6A100&\\4c&HD6A100&\\pos(%.1f,%.1f)}%s",
                            font_size,
                            x,
                            y,
                            item_text
                        )
                    end
                end
            else
                dropped_invalid = dropped_invalid + 1
            end
        else
            dropped_invalid = dropped_invalid + 1
        end
    end
    for i = kept_count + 1, old_comment_count do
        comments[i] = nil
    end
    for i = line_count + 1, old_line_count do
        lines[i] = nil
    end
    if dropped_invalid > 0 then
        msg.warn(string.format("bili_live_danmaku dropped invalid comments: %d", dropped_invalid))
    end

    if line_count == 0 then
        clear_overlay()
        record_render_perf(render_start, 0)
        return
    end

    if source_mode == "video" and not video_first_visible_logged then
        local wall = mp.get_time() or 0
        local raw = mp.get_property_number("time-pos", 0) or 0
        local delta = 0
        if video_load_wall_time then
            delta = wall - video_load_wall_time
            if delta < 0 then
                delta = 0
            end
        end
        msg.info(string.format(
            "bili_live_danmaku video first-visible lines=%d delta=%.3fs raw=%.3f now=%.3f x_min=%.1f x_max=%.1f w=%.1f",
            line_count,
            delta,
            raw,
            now_time,
            visible_min_x or -1,
            visible_max_x or -1,
            w
        ))
        video_first_visible_logged = true
    end

    apply_overlay_data(table.concat(lines, "\n", 1, line_count))
    record_render_perf(render_start, line_count)
end

local function run_curl(url, on_done, timeout_sec)
    local started_at = mp.get_time() or 0
    local timeout_value = tonumber(timeout_sec) or 5
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {
            "curl",
            "-L",
            "-s",
            "--compressed",
            "--max-time",
            string.format("%.0f", timeout_value),
            url,
        },
    }, function(success, result, err)
        local elapsed_ms = ((mp.get_time() or 0) - started_at) * 1000
        if not success or not result or result.status ~= 0 then
            on_done(nil, err or (result and result.stderr) or "curl failed", elapsed_ms)
            return
        end
        on_done(result.stdout, nil, elapsed_ms)
    end)
end

local function detect_room_short_id()
    if type(o.force_room_id) == "string" and o.force_room_id:match("^%d+$") then
        return o.force_room_id
    end

    local candidates = {
        mp.get_property("path", ""),
        mp.get_property("stream-open-filename", ""),
        mp.get_property("filename", ""),
        mp.get_property("force-media-title", ""),
        mp.get_property("media-title", ""),
    }

    for _, path in ipairs(candidates) do
        if type(path) == "string" and path ~= "" then
            local id = path:match("live%.bilibili%.com/blanc/(%d+)")
            if not id then
                id = path:match("m%.live%.bilibili%.com/(%d+)")
            end
            if not id then
                id = path:match("live%.bilibili%.com/(%d+)")
            end
            if id then
                return id
            end
        end
    end
    return nil
end

local function process_history(stdout)
    local parsed = utils.parse_json(stdout)
    if type(parsed) ~= "table" or parsed.code ~= 0 then
        return 0
    end
    local room = parsed.data and parsed.data.room
    if type(room) ~= "table" then
        return 0
    end
    local added_count = 0

    for i = #room, 1, -1 do
        local item = room[i]
        if type(item) == "table" and type(item.text) == "string" and item.text ~= "" then
            local id = item.id_str
            if type(id) ~= "string" or id == "" then
                id = string.format(
                    "%s|%s|%s",
                    tostring(item.timeline or ""),
                    tostring(item.uid or ""),
                    item.text
                )
            end
            if remember_seen(id) then
                add_comment(item.nickname or item.uname or "", item.text)
                added_count = added_count + 1
            end
        end
    end

    return added_count
end

local function fetch_history()
    if source_mode ~= "live" then
        return
    end
    if not active or not room_id or fetch_running then
        return
    end
    if not enabled then
        return
    end

    fetch_running = true
    local url = string.format(
        "https://api.live.bilibili.com/xlive/web-room/v1/dM/gethistory?roomid=%s&room_type=0",
        tostring(room_id)
    )

    run_curl(url, function(stdout, _, fetch_ms)
        fetch_running = false
        if not active then
            return
        end
        if not stdout then
            record_fetch_perf(fetch_ms or 0, true, nil, nil)
            return
        end

        local parse_start = mp.get_time() or 0
        local added_count = process_history(stdout)
        local parse_ms = ((mp.get_time() or 0) - parse_start) * 1000
        record_fetch_perf(fetch_ms or 0, false, parse_ms, added_count)
        if added_count > 0 then
            has_message = true
            no_message_polls = 0
        else
            no_message_polls = no_message_polls + 1
            local now_time = mp.get_time()
            if not has_message and no_message_polls >= 12 and (now_time - last_no_message_osd) > 25 then
                mp.osd_message("当前B站房间暂无可用弹幕", 2)
                last_no_message_osd = now_time
            end
        end
    end)
end

local function start_for_room(short_id)
    reload_runtime_options(true)
    if not curl_ok then
        msg.error("curl 不可用，无法获取直播弹幕")
        mp.osd_message("B站弹幕失败 curl不可用", 4)
        return
    end

    stop_all()
    source_mode = "live"
    local expected_short = tostring(short_id)
    room_short_id = expected_short

    local resolve_url = string.format(
        "https://api.live.bilibili.com/room/v1/Room/room_init?id=%s",
        room_short_id
    )

    run_curl(resolve_url, function(stdout, _, _)
        if room_short_id ~= expected_short then
            return
        end
        if not stdout then
            mp.osd_message("B站弹幕失败 房间解析失败", 4)
            return
        end

        local parsed = utils.parse_json(stdout)
        local resolved = parsed and parsed.data and parsed.data.room_id
        if not resolved then
            mp.osd_message("B站弹幕失败 房间解析失败", 4)
            return
        end

        room_id = tostring(resolved)
        active = true
        ensure_render_timer()
        if render_timer then
            render_timer:resume()
        end
        stop_poll_timer()
        poll_timer = mp.add_periodic_timer(o.poll_interval, fetch_history)
        fetch_history()
        mp.osd_message("B站弹幕已连接 房间 " .. tostring(room_short_id), 2)
        msg.info("bili_live_danmaku connected to room " .. tostring(room_short_id))
        sync_uosc_toggle_state()
    end)
end

local function start_for_video(bvid, page)
    reload_runtime_options(true)
    if not curl_ok then
        msg.error("curl 不可用，无法获取视频弹幕")
        mp.osd_message("B站弹幕失败 curl不可用", 4)
        return
    end
    if type(bvid) ~= "string" or bvid == "" then
        mp.osd_message("B站弹幕失败 BV号无效", 3)
        return
    end

    stop_all()
    source_mode = "video"
    begin_video_start_hold()
    video_bvid = bvid
    local target_page = tonumber(page) or 1
    if target_page < 1 then
        target_page = 1
    end

    local resolve_url = string.format("https://api.bilibili.com/x/player/pagelist?bvid=%s", bvid)
    run_curl(resolve_url, function(stdout, err_text)
        if source_mode ~= "video" or video_bvid ~= bvid then
            return
        end
        if not stdout then
            msg.info(
                "bili_live_danmaku video pagelist request failed bvid="
                .. tostring(bvid)
                .. " err="
                .. tostring(err_text)
            )
            mp.osd_message("B站弹幕失败 视频解析失败", 4)
            release_video_start_hold("pagelist_failed")
            return
        end

        local parsed = utils.parse_json(stdout)
        local data = parsed and parsed.data
        if type(data) ~= "table" or #data == 0 then
            msg.info(
                "bili_live_danmaku video pagelist parse failed bvid="
                .. tostring(bvid)
                .. " bytes="
                .. tostring(#stdout)
            )
            mp.osd_message("B站弹幕失败 视频解析失败", 4)
            release_video_start_hold("pagelist_parse_failed")
            return
        end

        local selected = data[1]
        for i = 1, #data do
            local item = data[i]
            if tonumber(item and item.page) == target_page then
                selected = item
                break
            end
        end

        local cid = selected and selected.cid
        if not cid then
            msg.info("bili_live_danmaku video cid not found bvid=" .. tostring(bvid))
            mp.osd_message("B站弹幕失败 CID解析失败", 4)
            release_video_start_hold("cid_not_found")
            return
        end
        video_cid = tostring(cid)

        local xml_url = string.format("https://comment.bilibili.com/%s.xml", video_cid)
        run_curl(xml_url, function(xml_text, err_text2)
            if source_mode ~= "video" or video_bvid ~= bvid then
                return
            end
            if not xml_text then
                msg.info(
                    "bili_live_danmaku video xml request failed bvid="
                    .. tostring(bvid)
                    .. " cid="
                    .. tostring(video_cid)
                    .. " err="
                    .. tostring(err_text2)
                )
                mp.osd_message("B站弹幕失败 弹幕拉取失败", 4)
                release_video_start_hold("xml_failed")
                return
            end

            local events = parse_video_danmaku_xml(xml_text)
            if #events == 0 then
                msg.info(
                    "bili_live_danmaku video xml parsed no events bvid="
                    .. tostring(bvid)
                    .. " cid="
                    .. tostring(video_cid)
                    .. " bytes="
                    .. tostring(#xml_text)
                )
                mp.osd_message("当前视频暂无可用弹幕", 3)
                release_video_start_hold("xml_no_events")
                return
            end

            video_events = events
            video_next_index = 1
            video_last_time = mp.get_property_number("time-pos", 0) or 0
            video_load_wall_time = mp.get_time() or 0
            video_first_visible_logged = false
            reset_video_clock()
            reset_video_active_comments()
            prefill_video_comments(video_last_time)
            align_video_next_index(video_last_time)

            active = true
            ensure_render_timer()
            if render_timer then
                render_timer:resume()
            end
            stop_poll_timer()
            mp.osd_message("B站视频弹幕已加载 " .. tostring(#events) .. " 条", 2)
            msg.info(
                "bili_live_danmaku loaded video danmaku bvid="
                .. tostring(video_bvid)
                .. " cid="
                .. tostring(video_cid)
                .. " count="
                .. tostring(#events)
            )
            release_video_start_hold("loaded")
            sync_uosc_toggle_state()
        end, 12)
    end, 8)
end

local function on_file_loaded()
    local short_id = detect_room_short_id()
    if short_id then
        start_for_room(short_id)
        return
    end

    local bvid, page = detect_video_bvid_and_page()
    if bvid then
        start_for_video(bvid, page)
        return
    end

    stop_all()
end

local function set_danmaku_enabled(new_state, silent_osd)
    new_state = not not new_state
    if enabled == new_state then
        sync_uosc_toggle_state()
        return
    end

    enabled = new_state
    if not enabled then
        clear_overlay()
    end

    if enabled then
        if not silent_osd then
            mp.osd_message("B站弹幕 已开启", 2)
        end
        if active then
            if source_mode == "video" and restart_danmaku then
                restart_danmaku()
            else
                fetch_history()
            end
        end
    else
        if not silent_osd then
            mp.osd_message("B站弹幕 已关闭", 2)
        end
    end
    sync_uosc_toggle_state()
end

local function toggle_danmaku()
    set_danmaku_enabled(not enabled, false)
end

restart_danmaku = function()
    reload_runtime_options(true)
    local short_id = detect_room_short_id()
    if short_id then
        start_for_room(short_id)
        return
    end

    local bvid, page = detect_video_bvid_and_page()
    if bvid then
        start_for_video(bvid, page)
        return
    end

    mp.osd_message("当前不是B站直播或视频链接", 2)
end

local function show_danmaku_keyboard()
    toggle_danmaku()
end

local function show_danmaku(action)
    msg.info("bili_live_danmaku show_danmaku action=" .. tostring(action))
    if type(action) ~= "string" then
        toggle_danmaku()
        return
    end

    local v = action:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if v == "on" or v == "toggle_on" or v == "1" or v == "true" then
        set_danmaku_enabled(true, true)
        return
    end
    if v == "off" or v == "toggle_off" or v == "0" or v == "false" then
        set_danmaku_enabled(false, true)
        return
    end
    if v == "on_off" or v == "toggle" then
        toggle_danmaku()
        return
    end

    toggle_danmaku()
end

local function handle_set_message(name, value)
    if type(name) ~= "string" then
        return
    end
    local key = name:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    msg.info("bili_live_danmaku set name=" .. tostring(name) .. " value=" .. tostring(value))
    if key == "show_danmaku" then
        show_danmaku(value)
    end
end

local function use_room_id(room_short)
    if type(room_short) ~= "string" then
        return
    end
    room_short = room_short:gsub("^%s+", ""):gsub("%s+$", "")
    if not room_short:match("^%d+$") then
        mp.osd_message("房间号无效", 2)
        return
    end
    o.force_room_id = room_short
    start_for_room(room_short)
end

local function slower_danmaku()
    duration = clamp(duration + 1.0, 4.0, 30.0)
    show_style_status()
end

local function faster_danmaku()
    duration = clamp(duration - 1.0, 4.0, 30.0)
    show_style_status()
end

local function smaller_font()
    font_size = math.floor(clamp(font_size - 2, 18, 72))
    show_style_status()
end

local function larger_font()
    font_size = math.floor(clamp(font_size + 2, 18, 72))
    show_style_status()
end

local function check_curl_available()
    local result = utils.subprocess({
        args = { "curl", "--version" },
        cancellable = false,
        max_size = 128,
    })
    if not result or result.status ~= 0 then
        curl_ok = false
        msg.error("curl 不可用")
    end
end

check_curl_available()
init_perf_log()
sync_uosc_toggle_state()

mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file", stop_all)
mp.register_script_message("bili-live-danmaku-toggle", toggle_danmaku)
mp.register_script_message("show_danmaku_keyboard", show_danmaku_keyboard)
mp.register_script_message("show_danmaku", show_danmaku)
mp.register_script_message("set", handle_set_message)
mp.register_script_message("bili-live-danmaku-restart", restart_danmaku)
mp.register_script_message("bili-live-danmaku-use-room", use_room_id)
mp.register_script_message("bili-live-danmaku-slower", slower_danmaku)
mp.register_script_message("bili-live-danmaku-faster", faster_danmaku)
mp.register_script_message("bili-live-danmaku-smaller", smaller_font)
mp.register_script_message("bili-live-danmaku-larger", larger_font)
