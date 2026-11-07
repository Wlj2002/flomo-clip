-- flomo-clip：在任意软件里选中文字后按快捷键，存入 flomo，标签为 #mac划线 + 来源软件
-- 用法：把本文件和 flomo_mcp.lua 放进 ~/.hammerspoon/，在 init.lua 里写 require("flomo_clip")
local flomoMcp = require("flomo_mcp")

-- ===== 可按需修改的设置 =====
local HOTKEY = { mods = { "ctrl" }, key = "f" }

local API_URL_FILE = hs.configdir .. "/flomo_api_url.txt"
local BASE_TAG = "mac划线"  -- 每条划线都会带的标签，不能有空格

-- 软件名 → 标签；不在表里的软件直接用软件名（去掉空格）
local APP_TAGS = {
  ["Google Chrome"] = "Chrome",
}

-- 在浏览器里划线时，按网站识别来源
local SITE_TAGS = {
  ["claude.ai"] = "Claude",
  ["chatgpt.com"] = "ChatGPT",
  ["chat.openai.com"] = "ChatGPT",
}

-- ===== 设置到此为止 =====

local BROWSER_URL_SCRIPTS = {
  ["com.google.Chrome"] = 'tell application "Google Chrome" to return URL of active tab of front window',
  ["com.apple.Safari"] = 'tell application "Safari" to return URL of front document',
}

-- 右下角小提示，配色参考 flomo：绿点表示成功，橙点表示出错；标签用 flomo 的蓝色标签样式
local TOAST_DOT = { ok = "#30CF79", error = "#F5A623" }
local TOAST_FONT = "PingFangSC-Regular"
local toastCanvas, toastTimer, toastClickTimer, toastSourceApp

local function styled(str, size, hex)
  return hs.styledtext.new(str, { font = { name = TOAST_FONT, size = size }, color = { hex = hex } })
end

local function dismissToast(fadeOut)
  if toastTimer then toastTimer:stop(); toastTimer = nil end
  if toastCanvas then
    -- delete 不接受显式的 nil 参数
    if fadeOut then toastCanvas:delete(fadeOut) else toastCanvas:delete() end
    toastCanvas = nil
  end
end

-- onEdit 不为空时多显示一个「编辑」按钮；鼠标停在提示上时不会消失
local function toast(message, tags, kind, onEdit)
  dismissToast()
  local front = hs.application.frontmostApplication()
  if front and front:bundleID() ~= hs.processInfo.bundleID then toastSourceApp = front end

  local PAD, H, MARGIN, SHADOW = 14, 34, 20, 12
  local msg = styled(message, 13, "#323232")
  local msgSize = hs.drawing.getTextDrawingSize(msg)
  local msgX = PAD + 16
  local x = msgX + msgSize.w
  local chips = {}
  for _, tag in ipairs(tags or {}) do
    local text = styled("#" .. tag, 11, "#5783F7")
    local size = hs.drawing.getTextDrawingSize(text)
    x = x + 6
    table.insert(chips, { text = text, size = size, x = x })
    x = x + size.w + 10
  end
  local editText, editSize, editX
  if onEdit then
    editText = styled("编辑", 12, "#1FA85E")
    editSize = hs.drawing.getTextDrawingSize(editText)
    editX = x + 10
    x = editX + editSize.w + 16
  end
  local W = x + PAD

  local screen = hs.screen.mainScreen():frame()
  local c = hs.canvas.new({
    x = screen.x + screen.w - W - MARGIN - SHADOW,
    y = screen.y + screen.h - H - MARGIN - SHADOW,
    w = W + 2 * SHADOW,
    h = H + 2 * SHADOW,
  })
  c:appendElements({
    type = "rectangle", action = "strokeAndFill", id = "card",
    trackMouseEnterExit = onEdit ~= nil,
    frame = { x = SHADOW, y = SHADOW, w = W, h = H },
    roundedRectRadii = { xRadius = 10, yRadius = 10 },
    fillColor = { white = 1, alpha = 0.82 },
    strokeColor = { white = 0, alpha = 0.06 }, strokeWidth = 0.5,
    withShadow = true,
    shadow = { blurRadius = 10, color = { white = 0, alpha = 0.12 }, offset = { h = -2, w = 0 } },
  }, {
    type = "circle", action = "fill",
    center = { x = SHADOW + PAD + 4, y = SHADOW + H / 2 }, radius = 4,
    fillColor = { hex = TOAST_DOT[kind] or TOAST_DOT.error },
  }, {
    type = "text", text = msg,
    frame = { x = SHADOW + msgX, y = SHADOW + (H - msgSize.h) / 2, w = msgSize.w + 4, h = msgSize.h },
  })
  for _, chip in ipairs(chips) do
    local chipH = chip.size.h + 4
    c:appendElements({
      type = "rectangle", action = "fill",
      frame = { x = SHADOW + chip.x, y = SHADOW + (H - chipH) / 2, w = chip.size.w + 10, h = chipH },
      roundedRectRadii = { xRadius = 4, yRadius = 4 },
      fillColor = { hex = "#EEF3FE", alpha = 0.9 },
    }, {
      type = "text", text = chip.text,
      frame = { x = SHADOW + chip.x + 5, y = SHADOW + (H - chip.size.h) / 2, w = chip.size.w + 4, h = chip.size.h },
    })
  end
  local visibleFor = onEdit and 4 or 1.8
  local function startDismissTimer()
    if toastTimer then toastTimer:stop() end
    toastTimer = hs.timer.doAfter(visibleFor, function() dismissToast(0.3) end)
  end
  if onEdit then
    local BUTTON_FILL = { hex = "#30CF79", alpha = 0.16 }
    local BUTTON_HOVER = { hex = "#30CF79", alpha = 0.3 }
    local buttonH = editSize.h + 4
    local buttonIndex = c:elementCount() + 1
    local hovering = {}
    c:appendElements({
      type = "rectangle", action = "fill", id = "edit",
      trackMouseEnterExit = true, trackMouseUp = true,
      frame = { x = SHADOW + editX, y = SHADOW + (H - buttonH) / 2, w = editSize.w + 16, h = buttonH },
      roundedRectRadii = { xRadius = 5, yRadius = 5 },
      fillColor = BUTTON_FILL,
    }, {
      type = "text", text = editText,
      frame = { x = SHADOW + editX + 8, y = SHADOW + (H - editSize.h) / 2, w = editSize.w + 4, h = editSize.h },
    })
    c:clickActivating(false)
    c:mouseCallback(function(_, event, id)
      if event == "mouseEnter" then
        hovering[id] = true
        if toastTimer then toastTimer:stop(); toastTimer = nil end
        if id == "edit" then c[buttonIndex].fillColor = BUTTON_HOVER end
      elseif event == "mouseExit" then
        hovering[id] = nil
        if next(hovering) == nil then startDismissTimer() end
        if id == "edit" then c[buttonIndex].fillColor = BUTTON_FILL end
      elseif event == "mouseUp" and id == "edit" then
        -- 不能在画布自己的回调里删除它，放到下一轮执行
        toastClickTimer = hs.timer.doAfter(0, function()
          dismissToast()
          onEdit()
        end)
      end
    end)
  end
  c:level(hs.canvas.windowLevels.overlay)
  c:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
  c:show(0.15)

  toastCanvas = c
  startDismissTimer()
  return c
end

-- 右下角的小编辑框：保存时通过 flomo MCP 改写刚存的那条笔记，取消则保持原样
local EDITOR_W, EDITOR_H, EDITOR_MARGIN = 420, 240, 20
local EDITOR_HTML = [[
<!doctype html><html><head><meta charset="utf-8"><style>
  * { box-sizing: border-box; margin: 0; }
  html, body { height: 100%; background: transparent; overflow: hidden; }
  body { font: 14px/1.6 "PingFang SC", sans-serif; color: #323232; }
  .card { height: 100%; display: flex; flex-direction: column; padding: 14px 14px 10px;
          background: rgba(255,255,255,.94); border: .5px solid rgba(0,0,0,.08); border-radius: 12px; }
  textarea { flex: 1; width: 100%; border: 0; outline: 0; resize: none; background: transparent;
             font: inherit; color: inherit; }
  .bar { display: flex; align-items: center; gap: 8px; padding-top: 8px; }
  .status { flex: 1; font-size: 12px; color: #9b9b9b; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .status.error { color: #E0862A; }
  button { font: inherit; font-size: 12px; padding: 3px 12px; border: 0; border-radius: 5px; cursor: pointer; }
  #cancel { background: rgba(0,0,0,.05); color: #666; }
  #save { background: #30CF79; color: #fff; }
  #save:disabled { opacity: .5; cursor: default; }
</style></head><body><div class="card">
  <textarea id="text" spellcheck="false"></textarea>
  <div class="bar">
    <div class="status" id="status">⌘↵ 保存 · Esc 取消</div>
    <button id="cancel">取消</button><button id="save">保存</button>
  </div>
</div><script>
  const text = document.getElementById("text"), save = document.getElementById("save");
  const status = document.getElementById("status");
  const post = message => window.webkit.messageHandlers.flomoEditor.postMessage(message);
  function submit() {
    if (save.disabled) return;
    save.disabled = true;
    status.className = "status";
    status.textContent = "保存中…";
    post({ action: "save", content: text.value });
  }
  function showError(message) {
    save.disabled = false;
    status.className = "status error";
    status.textContent = message;
  }
  save.onclick = submit;
  document.getElementById("cancel").onclick = () => post({ action: "cancel" });
  document.addEventListener("keydown", e => {
    if (e.key === "Escape") post({ action: "cancel" });
    if (e.key === "Enter" && e.metaKey) { e.preventDefault(); submit(); }
  });
  text.value = __INITIAL__.content;
  text.focus();
  const tagLine = text.value.lastIndexOf("\n\n#");
  const caret = tagLine >= 0 ? tagLine : text.value.length;
  text.setSelectionRange(caret, caret);
</script></body></html>
]]

local editorView, editorContent, editorPreviousApp

local function closeEditor()
  if editorView then editorView:delete(); editorView = nil end
  editorContent = nil
  if editorPreviousApp then editorPreviousApp:activate(); editorPreviousApp = nil end
end

local openEditor

local function saveEditedMemo(memoId, content, tags)
  local function showEditorError(message)
    if editorView then
      editorView:evaluateJavaScript("showError(" .. hs.json.encode({ message })  .. "[0])")
    end
  end
  flomoMcp.call("memo_update", { id = memoId, content = content }, function(result, err)
    if result then
      closeEditor()
      toast("已更新 flomo", tags, "ok", function() openEditor(memoId, content, tags) end)
    elseif err == "need_auth" then
      showEditorError("请在浏览器里授权 flomo，完成后再点一次保存")
      flomoMcp.authorize(function(ok, authErr)
        if not ok then showEditorError("授权失败：" .. tostring(authErr)) end
      end)
    else
      showEditorError("保存失败：" .. tostring(err))
    end
  end)
end

openEditor = function(memoId, content, tags)
  closeEditor()
  local controller = hs.webview.usercontent.new("flomoEditor")
  controller:setCallback(function(message)
    local body = message.body or {}
    if body.action == "cancel" then
      closeEditor()
    elseif body.action == "save" then
      saveEditedMemo(memoId, body.content, tags)
    end
  end)
  editorContent = controller
  -- 点击提示可能让 Hammerspoon 变成前台，此时回到显示提示时的软件
  local front = hs.application.frontmostApplication()
  editorPreviousApp = (front and front:bundleID() ~= hs.processInfo.bundleID) and front or toastSourceApp

  local screen = hs.screen.mainScreen():frame()
  local initial = hs.json.encode({ content = content }):gsub("</", "<\\/")
  local html = EDITOR_HTML:gsub("__INITIAL__", function() return initial end)
  editorView = hs.webview.new({
    x = screen.x + screen.w - EDITOR_W - EDITOR_MARGIN,
    y = screen.y + screen.h - EDITOR_H - EDITOR_MARGIN,
    w = EDITOR_W,
    h = EDITOR_H,
  }, { developerExtrasEnabled = false }, controller)
  editorView:windowStyle({ "borderless" })
  editorView:transparent(true)
  editorView:allowTextEntry(true)
  editorView:shadow(true)
  editorView:level(hs.drawing.windowLevels.floating)
  editorView:html(html)
  -- 不能用 hswindow():focus()：对自身窗口调用辅助功能接口会卡住主线程约 6 秒
  hs.focus()
  editorView:show()
end

-- 第一次编辑时先在浏览器里授权一次，之后直接打开编辑框
local function editMemo(memoId, content, tags)
  if flomoMcp.isAuthorized() then
    openEditor(memoId, content, tags)
    return
  end
  toast("请在浏览器里授权 flomo", nil, "ok")
  flomoMcp.authorize(function(ok, err)
    if ok then
      openEditor(memoId, content, tags)
    else
      toast("授权失败：" .. tostring(err), nil, "error")
    end
  end)
end

local function readApiUrl()
  local f = io.open(API_URL_FILE, "r")
  if not f then return nil end
  local url = f:read("*a"):match("https?://%S+")
  f:close()
  return url
end

local function siteTag(app)
  local script = BROWSER_URL_SCRIPTS[app:bundleID()]
  if not script then return nil end
  local ok, url = hs.osascript.applescript(script)
  local host = ok and type(url) == "string" and url:match("^%a[%w+.-]*://([^/:?#]+)")
  if not host then return nil end
  for domain, tag in pairs(SITE_TAGS) do
    if host == domain or host:sub(-#domain - 1) == "." .. domain then return tag end
  end
  return nil
end

local function sourceTag(app)
  local name = app:name()
  local tag = siteTag(app) or APP_TAGS[name] or name
  return (tag:gsub("%s", ""))
end

-- 模拟 Cmd+C 取选中文字，取完后恢复剪贴板原内容
local copyTimer
local function copySelection(callback)
  local saved = hs.pasteboard.readAllData()
  local before = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({"cmd"}, "c", 0)
  local tries = 0
  copyTimer = hs.timer.doEvery(0.05, function()
    tries = tries + 1
    local changed = hs.pasteboard.changeCount() ~= before
    if changed or tries >= 10 then
      copyTimer:stop()
      local text = changed and hs.pasteboard.getContents() or nil
      if changed then hs.pasteboard.writeAllData(saved) end
      callback(text)
    end
  end)
end

local function sendToFlomo(content, tags)
  local url = readApiUrl()
  if not url then
    toast("还没有填写 flomo API 地址（flomo_api_url.txt）", nil, "error")
    return
  end
  hs.http.asyncPost(url, hs.json.encode({content = content}), {["Content-Type"] = "application/json"},
    function(status, body)
      local ok, resp = pcall(hs.json.decode, body or "")
      resp = ok and type(resp) == "table" and resp or {}
      if status == 200 and (resp.code == nil or resp.code == 0) then
        local memoId = type(resp.memo) == "table" and resp.memo.slug or nil
        flomoClip.lastMemoId = memoId
        toast("已存入 flomo", tags, "ok", memoId and function() editMemo(memoId, content, tags) end or nil)
      else
        toast("存入 flomo 失败：" .. (resp.message or ("HTTP " .. tostring(status))), nil, "error")
      end
    end)
end

local function clipToFlomo()
  if not hs.accessibilityState(true) then
    toast("请先在「系统设置 → 隐私与安全性 → 辅助功能」里打开 Hammerspoon", nil, "error")
    return
  end
  local app = hs.application.frontmostApplication()
  copySelection(function(text)
    text = text and text:match("^%s*(.-)%s*$")
    if not text or text == "" then
      toast("没有选中文字", nil, "error")
      return
    end
    local tags = { BASE_TAG }
    local tag = sourceTag(app)
    if tag ~= "" and tag ~= BASE_TAG then table.insert(tags, tag) end
    local tagText = "#" .. table.concat(tags, " #")
    sendToFlomo(text .. "\n\n" .. tagText, tags)
  end)
end

-- 放在全局表里，避免被垃圾回收；也方便在 Hammerspoon 控制台里调试
flomoClip = {
  sourceTag = sourceTag,
  toast = toast,
  mcp = flomoMcp,
  openEditor = openEditor,
  closeEditor = closeEditor,
  editorView = function() return editorView end,
  hotkey = hs.hotkey.bind(HOTKEY.mods, HOTKEY.key, clipToFlomo),
}

return flomoClip
