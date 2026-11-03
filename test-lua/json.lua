-- Lector de JSON mínimo, solo para las pruebas (lee test-vectors/*.json). No va en el addon.
-- json.decode(texto) devuelve tablas de Lua; null se lee como json.null para que las listas conserven su
-- longitud y se distinga "clave con null" de "clave que no está". Un JSON mal formado lanza un error con la posición.
local json = {}
json.null = setmetatable({}, {__tostring = function() return "null" end})

local escapes = {['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t"}

local function utf8(code)
  if code < 0x80 then return string.char(code) end
  if code < 0x800 then return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40) end
  if code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
  end
  return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
                     0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

function json.decode(text)
  local pos = 1
  local function fail(what) error(string.format("JSON no válido en la posición %d: %s", pos, what), 0) end
  local function skip() pos = text:find("[^ \t\r\n]", pos) or (#text + 1) end
  local value

  local function str()
    pos = pos + 1
    local out = {}
    while true do
      local stop = text:find('["\\]', pos)
      if not stop then fail("cadena sin cerrar") end
      out[#out + 1] = text:sub(pos, stop - 1)
      if text:sub(stop, stop) == '"' then pos = stop + 1; break end
      local kind = text:sub(stop + 1, stop + 1)
      if kind == "u" then
        local hex = text:sub(stop + 2, stop + 5)
        if not hex:match("^%x%x%x%x$") then fail("\\u sin 4 cifras") end
        local code = tonumber(hex, 16)
        pos = stop + 6
        if code >= 0xD800 and code <= 0xDBFF and text:sub(pos, pos + 1) == "\\u" then
          local low = tonumber(text:sub(pos + 2, pos + 5), 16)
          if low and low >= 0xDC00 and low <= 0xDFFF then
            code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
            pos = pos + 6
          end
        end
        out[#out + 1] = utf8(code)
      elseif escapes[kind] then
        out[#out + 1] = escapes[kind]
        pos = stop + 2
      else
        fail("escape desconocido")
      end
    end
    return table.concat(out)
  end

  local function num()
    local s, e = text:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not s then fail("valor inesperado") end
    local n = tonumber(text:sub(s, e))
    if not n then fail("número") end
    pos = e + 1
    return n
  end

  local function literal(word, result)
    if text:sub(pos, pos + #word - 1) ~= word then fail("valor inesperado") end
    pos = pos + #word
    return result
  end

  function value()
    skip()
    local c = text:sub(pos, pos)
    if c == "{" then
      local obj = {}
      pos = pos + 1; skip()
      if text:sub(pos, pos) == "}" then pos = pos + 1; return obj end
      while true do
        skip()
        if text:sub(pos, pos) ~= '"' then fail("se esperaba una clave") end
        local key = str()
        skip()
        if text:sub(pos, pos) ~= ":" then fail("se esperaba ':'") end
        pos = pos + 1
        obj[key] = value()
        skip()
        local sep = text:sub(pos, pos)
        pos = pos + 1
        if sep == "}" then return obj end
        if sep ~= "," then fail("se esperaba ',' o '}'") end
      end
    elseif c == "[" then
      local list = {}
      pos = pos + 1; skip()
      if text:sub(pos, pos) == "]" then pos = pos + 1; return list end
      while true do
        list[#list + 1] = value()
        skip()
        local sep = text:sub(pos, pos)
        pos = pos + 1
        if sep == "]" then return list end
        if sep ~= "," then fail("se esperaba ',' o ']'") end
      end
    elseif c == '"' then
      return str()
    elseif c == "t" then
      return literal("true", true)
    elseif c == "f" then
      return literal("false", false)
    elseif c == "n" then
      return literal("null", json.null)
    end
    return num()
  end

  local result = value()
  skip()
  if pos <= #text then fail("texto de más tras el valor") end
  return result
end

return json
