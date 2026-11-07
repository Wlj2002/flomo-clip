-- flomo 官方 MCP 接口的最小客户端：浏览器授权一次（OAuth + PKCE），之后用本地 token 调用工具
local M = {}

local BASE = "https://flomoapp.com"
local MCP_URL = BASE .. "/mcp"
local TOKEN_FILE = hs.configdir .. "/flomo_oauth.json"
local CALLBACK_PORT = 53682
local REDIRECT_URI = "http://127.0.0.1:" .. CALLBACK_PORT .. "/callback"
local AUTH_TIMEOUT = 300

local state = hs.fs.attributes(TOKEN_FILE) and hs.json.read(TOKEN_FILE) or {}
local authServer, authTimer, stopTimer

local function saveState()
  hs.json.write(state, TOKEN_FILE, true, true)
  os.execute("chmod 600 '" .. TOKEN_FILE .. "'")
end

local function base64url(data)
  return (hs.base64.encode(data):gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

local function randomToken()
  local f = io.open("/dev/urandom", "rb")
  local bytes = f:read(32)
  f:close()
  return base64url(bytes)
end

local function formEncode(fields)
  local parts = {}
  for k, v in pairs(fields) do
    local encoded = v:gsub("[^%w%-%._~]", function(ch) return string.format("%%%02X", ch:byte()) end)
    table.insert(parts, k .. "=" .. encoded)
  end
  return table.concat(parts, "&")
end

local function decodeJson(body)
  local ok, value = pcall(hs.json.decode, body or "")
  return ok and type(value) == "table" and value or nil
end

local function postToken(fields, callback)
  hs.http.asyncPost(BASE .. "/oauth/token", formEncode(fields), {["Content-Type"] = "application/x-www-form-urlencoded"},
    function(status, body)
      local resp = decodeJson(body)
      if status ~= 200 or not resp or not resp.access_token then
        callback(false, (resp and (resp.error_description or resp.error)) or ("HTTP " .. tostring(status)))
        return
      end
      state.access_token = resp.access_token
      state.refresh_token = resp.refresh_token or state.refresh_token
      state.expires_at = resp.expires_in and (os.time() + resp.expires_in) or nil
      saveState()
      callback(true)
    end)
end

function M.isAuthorized()
  return state.access_token ~= nil
end

local function stopAuthServer()
  if authTimer then authTimer:stop(); authTimer = nil end
  if authServer then authServer:stop(); authServer = nil end
end

-- 打开浏览器让用户授权；授权结果由本机回调页面接收
function M.authorize(callback)
  stopAuthServer()
  local registration = hs.json.encode({
    client_name = "Hammerspoon flomo clip",
    redirect_uris = { REDIRECT_URI },
    grant_types = { "authorization_code", "refresh_token" },
    response_types = { "code" },
    token_endpoint_auth_method = "none",
    scope = "mcp",
  })
  hs.http.asyncPost(BASE .. "/oauth/register", registration, {["Content-Type"] = "application/json"}, function(status, body)
    local client = decodeJson(body)
    if not client or not client.client_id then
      callback(false, "注册授权客户端失败：HTTP " .. tostring(status))
      return
    end
    state = { client_id = client.client_id }

    local verifier, expectedState = randomToken(), randomToken()
    authServer = hs.httpserver.new(false, false)
    authServer:setInterface("localhost")
    authServer:setPort(CALLBACK_PORT)
    authServer:setCallback(function(_, path)
      local query = {}
      for _, item in ipairs(hs.http.urlParts("http://localhost" .. path).queryItems or {}) do
        for k, v in pairs(item) do query[k] = v end
      end
      local page = { ["Content-Type"] = "text/html; charset=utf-8" }
      if not path:match("^/callback") or query.state ~= expectedState then
        return "无效的请求", 400, page
      end
      stopTimer = hs.timer.doAfter(1, stopAuthServer)
      if not query.code then
        callback(false, query.error or "授权被取消")
        return "授权未完成，可以关闭这个页面了。", 200, page
      end
      postToken({
        grant_type = "authorization_code",
        code = query.code,
        redirect_uri = REDIRECT_URI,
        client_id = state.client_id,
        code_verifier = verifier,
        resource = MCP_URL,
      }, callback)
      return "授权完成，可以关闭这个页面了。", 200, page
    end)
    authServer:start()
    authTimer = hs.timer.doAfter(AUTH_TIMEOUT, function()
      stopAuthServer()
      callback(false, "等待授权超时")
    end)

    hs.urlevent.openURL(BASE .. "/integration/grant?" .. formEncode({
      response_type = "code",
      client_id = state.client_id,
      redirect_uri = REDIRECT_URI,
      scope = "mcp",
      state = expectedState,
      code_challenge = base64url(hs.hash.bSHA256(verifier)),
      code_challenge_method = "S256",
      resource = MCP_URL,
    }))
  end)
end

local function refresh(callback)
  if not state.refresh_token then
    state = {}
    saveState()
    callback(false, "need_auth")
    return
  end
  postToken({
    grant_type = "refresh_token",
    refresh_token = state.refresh_token,
    client_id = state.client_id,
    resource = MCP_URL,
  }, function(ok, err)
    if ok then
      callback(true)
    else
      state = {}
      saveState()
      callback(false, "need_auth")
    end
  end)
end

-- MCP 响应可能是 JSON，也可能是 SSE；SSE 取最后一条 data
local function parseRpcBody(body)
  if not body then return nil end
  local data
  for line in body:gmatch("[^\r\n]+") do
    local payload = line:match("^data:%s*(.*)$")
    if payload then data = payload end
  end
  return decodeJson(data or body)
end

local function headerValue(headers, name)
  for k, v in pairs(headers or {}) do
    if k:lower() == name then return v end
  end
  return nil
end

local function post(sessionId, json, callback)
  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json, text/event-stream",
    ["Authorization"] = "Bearer " .. state.access_token,
  }
  if sessionId then headers["Mcp-Session-Id"] = sessionId end
  hs.http.asyncPost(MCP_URL, json, headers, function(status, body, respHeaders)
    callback(status, parseRpcBody(body), respHeaders)
  end)
end

-- 这两条写成字面 JSON：hs.json 会把空表编码成 []，而 MCP 要求 capabilities 是对象
local INITIALIZE = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"hammerspoon-flomo-clip","version":"1.0"}}}'
local INITIALIZED = '{"jsonrpc":"2.0","method":"notifications/initialized"}'

local function callAuthorized(tool, args, callback, retried)
  post(nil, INITIALIZE, function(status, _, headers)
    if status == 401 and not retried then
      refresh(function(ok, err)
        if ok then callAuthorized(tool, args, callback, true) else callback(nil, err) end
      end)
      return
    end
    if status ~= 200 then
      callback(nil, status == 401 and "need_auth" or ("HTTP " .. tostring(status)))
      return
    end
    local sessionId = headerValue(headers, "mcp-session-id")
    post(sessionId, INITIALIZED, function()
      local request = hs.json.encode({
        jsonrpc = "2.0", id = 2, method = "tools/call",
        params = { name = tool, arguments = args },
      })
      post(sessionId, request, function(callStatus, resp)
        local result = resp and resp.result
        local firstText = result and result.content and result.content[1] and result.content[1].text
        if callStatus ~= 200 or not result then
          callback(nil, (resp and resp.error and resp.error.message) or ("HTTP " .. tostring(callStatus)))
        elseif result.isError then
          callback(nil, firstText or "调用失败")
        else
          callback(firstText or "")
        end
      end)
    end)
  end)
end

-- 调用 MCP 工具。callback(结果文本) 或 callback(nil, 错误)；错误为 "need_auth" 时需要重新授权
function M.call(tool, args, callback)
  if not state.access_token then
    callback(nil, "need_auth")
  elseif state.expires_at and state.expires_at - 60 < os.time() then
    refresh(function(ok, err)
      if ok then callAuthorized(tool, args, callback) else callback(nil, err) end
    end)
  else
    callAuthorized(tool, args, callback)
  end
end

return M
