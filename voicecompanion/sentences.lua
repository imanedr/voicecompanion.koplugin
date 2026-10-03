--[[--
Split plain text (AI answers) into speakable chunks: sentences, with very
short ones merged and very long ones split at commas/semicolons.  Book text
uses crengine's own segmentation instead (see reader/booktext.lua).
--]]

local Sentences = {
    MIN_LEN = 25,
    MAX_LEN = 350,
}

local ABBREVIATIONS = {
    mr = true, mrs = true, ms = true, dr = true, prof = true, st = true, jr = true, sr = true,
    vs = true, etc = true, ["e.g"] = true, ["i.e"] = true, no = true, vol = true, fig = true,
}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

--- Raw sentence split.
function Sentences.split(text)
    local out = {}
    text = text:gsub("\r", "")
    -- Paragraph breaks always end a sentence.
    for para in (text .. "\n\n"):gmatch("(.-)\n%s*\n") do
        para = trim(para:gsub("%s+", " "))
        local start = 1
        local i = 1
        while i <= #para do
            local c = para:sub(i, i)
            local ellipsis = para:sub(i, i + 2) == "\226\128\166"
            if c == "." or c == "!" or c == "?" or ellipsis then
                -- Include closing quotes/brackets and repeated punctuation.
                local j = ellipsis and i + 2 or i
                while j < #para and para:sub(j + 1, j + 1):match("[%.!?\"')%]]") do j = j + 1 end
                -- Multi-byte closing quotes (” ’ »).
                while para:sub(j + 1, j + 3) == "\226\128\157" or para:sub(j + 1, j + 3) == "\226\128\153" do j = j + 3 end
                while para:sub(j + 1, j + 2) == "\194\187" do j = j + 2 end
                local nxt = para:sub(j + 1, j + 1)
                local word = para:sub(start, i - 1):match("([%a%.]+)$")
                local is_abbrev = c == "." and word and ABBREVIATIONS[word:lower()]
                local is_decimal = c == "." and para:sub(i - 1, i - 1):match("%d") and nxt:match("%d")
                if (nxt == "" or nxt == " ") and not is_abbrev and not is_decimal then
                    table.insert(out, trim(para:sub(start, j)))
                    start = j + 2
                    i = j + 1
                end
            end
            i = i + 1
        end
        if start <= #para then
            local rest = trim(para:sub(start))
            if rest ~= "" then table.insert(out, rest) end
        end
    end
    return out
end

local function splitLong(s, max_len)
    if #s <= max_len then return { s } end
    local parts, current = {}, ""
    for piece in (s .. " "):gmatch("(.-[,;:]?)%s") do
        if #current + #piece + 1 > max_len and current ~= "" then
            table.insert(parts, current)
            current = piece
        else
            current = current == "" and piece or (current .. " " .. piece)
        end
    end
    if current ~= "" then table.insert(parts, current) end
    return parts
end

--- Speakable chunks: short sentences merged, long ones split.
function Sentences.chunks(text, min_len, max_len)
    min_len = min_len or Sentences.MIN_LEN
    max_len = max_len or Sentences.MAX_LEN
    local out = {}
    local pending = ""
    for _i, s in ipairs(Sentences.split(text)) do
        pending = pending == "" and s or (pending .. " " .. s)
        if #pending >= min_len then
            for _j, part in ipairs(splitLong(pending, max_len)) do table.insert(out, part) end
            pending = ""
        end
    end
    if pending ~= "" then
        if #out > 0 and #out[#out] + #pending < max_len then
            out[#out] = out[#out] .. " " .. pending
        else
            table.insert(out, pending)
        end
    end
    return out
end

return Sentences
