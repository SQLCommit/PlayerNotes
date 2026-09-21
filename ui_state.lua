-- Shared palette and text helpers; no addon-module dependencies to avoid require cycles.

local state = {};

-- Shared color palette.
state.colors = {
    header    = { 1.0, 0.65, 0.26, 1.0 },
    success   = { 0.0, 1.0, 0.1, 1.0 },
    error     = { 1.0, 0.4, 0.4, 1.0 },
    muted     = { 0.6, 0.6, 0.6, 1.0 },
    star_on   = { 1.0, 0.85, 0.0, 1.0 },
    star_off  = { 0.4, 0.4, 0.4, 1.0 },
    player    = { 0.4, 1.0, 1.0, 1.0 },
    card_bg     = { 0.16, 0.16, 0.20, 1.0 },
    card_pinned = { 0.18, 0.17, 0.14, 1.0 },
    accent_gold = { 1.0, 0.75, 0.0, 1.0 },
    accent_gray = { 0.4, 0.4, 0.4, 1.0 },
};

-- Trim trailing NULs (from fixed ImGui input buffers) and trailing whitespace.
function state.trim_buf(s)
    if (type(s) == 'string') then
        return s:gsub('%z+$', ''):gsub('[%s]+$', '');
    end
    return '';
end

return state;
